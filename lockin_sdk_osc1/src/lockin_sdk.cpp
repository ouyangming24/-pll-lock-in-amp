// =============================================================================
// Lock-In Osc1 Stream SDK — 实现
// 协议: SDKOUT 28 字节帧 (见 usb_commend.v / lock_in_amp.v)
// =============================================================================
#include "lockin_osc1/lockin_sdk.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

#include "serial_port.h"

namespace lockin_osc1 {
namespace {

constexpr uint8_t kFrameSync[4] = {0xA5, 0x5A, 0xC3, 0x01};
constexpr size_t  kFrameLen     = 28;
constexpr size_t  kFrameDataLen = 26;  // CRC 覆盖 [0..25]

constexpr const char* kRespOk  = "Command Success!";
constexpr const char* kRespErr = "Command Error!";
constexpr size_t kRespMaxLen   = 16;

constexpr double kPi = 3.14159265358979323846;

constexpr int kReadTimeoutMs  = 20;
constexpr int kProbeTries     = 3;
constexpr int kProbeTimeoutMs = 300;

// 码值 → 电压 (与经典 SDK / GUI 相同)
const double kCicGainEff = std::pow(65.0, 5) / 2147483648.0;
const double kGTotal     = (8192.0 / 9.75) * 8192.0 * 0.5 * kCicGainEff;
std::atomic<double> g_vPerLsb{0.9966 / kGTotal};

uint16_t crc16(const uint8_t* p, size_t n) {
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; ++i) {
        c ^= static_cast<uint16_t>(p[i]) << 8;
        for (int k = 0; k < 8; ++k)
            c = (c & 0x8000) ? static_cast<uint16_t>((c << 1) ^ 0x1021) : static_cast<uint16_t>(c << 1);
    }
    return c;
}

uint16_t be16(const uint8_t* p) { return static_cast<uint16_t>((p[0] << 8) | p[1]); }
uint32_t be32(const uint8_t* p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8) | p[3];
}

size_t findSync(const std::vector<uint8_t>& b, size_t from) {
    if (b.size() < 4) return std::string::npos;
    for (size_t i = from; i + 4 <= b.size(); ++i)
        if (b[i] == kFrameSync[0] && b[i + 1] == kFrameSync[1] &&
            b[i + 2] == kFrameSync[2] && b[i + 3] == kFrameSync[3])
            return i;
    return std::string::npos;
}

void decodeFrame(const uint8_t* p, Frame& f) {
    f.osc1X       = static_cast<int32_t>(be32(p + 4));
    f.osc1Y       = static_cast<int32_t>(be32(p + 8));
    f.v3          = static_cast<int16_t>(be16(p + 12));
    f.v4          = static_cast<int16_t>(be16(p + 14));
    f.v5          = static_cast<int16_t>(be16(p + 16));
    f.sampleCount = be32(p + 18);
    f.frameSeq    = be32(p + 22);
}

}  // namespace

// =============================================================================
uint64_t hzToFreqWord(double hz) {
    long long w = std::llround(hz * std::ldexp(1.0, kPhaseBits) / kClockHz);
    if (w < 0) w = 0;
    return static_cast<uint64_t>(w) & ((uint64_t(1) << kPhaseBits) - 1);
}

double freqWordToHz(uint64_t word) {
    return static_cast<double>(word) * kClockHz / std::ldexp(1.0, kPhaseBits);
}

double voltsPerLsb() { return g_vPerLsb.load(); }
void   setVoltsPerLsb(double v) { g_vPerLsb.store(v); }

double adcRangePeakVolts(AdcRange r) {
    switch (r) {
        case AdcRange::Bipolar2V5:  return 2.5;
        case AdcRange::Bipolar5V:   return 5.0;
        case AdcRange::Bipolar6V25: return 6.25;
        case AdcRange::Bipolar10V:  return 10.0;
        case AdcRange::Bipolar12V5: return 12.5;
        default: return 0.0;
    }
}

double Frame::osc1XVolts() const { return osc1X * voltsPerLsb(); }
double Frame::osc1YVolts() const { return osc1Y * voltsPerLsb(); }
double Frame::osc1RVolts() const { return std::hypot(osc1XVolts(), osc1YVolts()); }
double Frame::osc1PhaseDeg() const {
    return std::atan2(static_cast<double>(osc1Y), static_cast<double>(osc1X)) * 180.0 / kPi;
}
double Frame::v3Volts(AdcRange range) const {
    double pk = adcRangePeakVolts(range);
    return pk > 0.0 ? v3 * (pk / 32768.0) : 0.0;
}
double Frame::v4Volts(AdcRange range) const {
    double pk = adcRangePeakVolts(range);
    return pk > 0.0 ? v4 * (pk / 32768.0) : 0.0;
}

// =============================================================================
struct LockinDevice::Impl {
    detail::SerialPort port;
    std::string portName;
    uint32_t baud = kDefaultBaud;
    AdcRange rngV3 = AdcRange::Bipolar10V;
    AdcRange rngV4 = AdcRange::Bipolar10V;

    std::thread reader;
    std::atomic<bool> running{false};
    std::atomic<bool> portLost{false};
    std::atomic<std::thread::id> readerId{std::thread::id()};
    std::vector<uint8_t> rxBuf;
    std::string respTail;

    std::mutex cmdMutex;
    std::mutex respMutex;
    std::condition_variable respCv;
    uint64_t respCount = 0;
    bool lastRespOk = false;
    std::atomic<int> cmdTimeoutMs{500};

    mutable std::mutex dataMutex;
    Frame lastFrame;
    bool haveFrame = false;
    FrameCallback frameCb;
    std::atomic<uint64_t> nFrames{0}, nCrcErr{0};
    std::atomic<bool> streaming{false};

    mutable std::mutex errMutex;
    std::string err;

    void setError(const std::string& e) {
        std::lock_guard<std::mutex> g(errMutex);
        err = e;
    }

    void readerLoop() {
        readerId = std::this_thread::get_id();
        uint8_t tmp[4096];
        while (running.load()) {
            int n = port.read(tmp, sizeof(tmp));
            if (n < 0) {
                portLost = true;
                setError("serial port read failed (device unplugged?)");
                respCv.notify_all();
                break;
            }
            if (n > 0) feed(tmp, static_cast<size_t>(n));
        }
    }

    void scanResponses(const uint8_t* p, size_t n) {
        std::string s = respTail;
        s.append(reinterpret_cast<const char*>(p), n);
        size_t pos = 0, consumed = 0;
        int hits = 0;
        bool ok = false;
        while (pos < s.size()) {
            size_t a = s.find(kRespOk, pos), b = s.find(kRespErr, pos);
            if (a == std::string::npos && b == std::string::npos) break;
            if (a != std::string::npos && (b == std::string::npos || a < b)) {
                ok = true;
                pos = consumed = a + std::strlen(kRespOk);
            } else {
                ok = false;
                pos = consumed = b + std::strlen(kRespErr);
            }
            ++hits;
        }
        size_t keepFrom = std::max(consumed, s.size() > kRespMaxLen - 1 ? s.size() - (kRespMaxLen - 1) : 0);
        respTail = s.substr(keepFrom);
        if (hits) {
            {
                std::lock_guard<std::mutex> g(respMutex);
                respCount += hits;
                lastRespOk = ok;
            }
            respCv.notify_all();
        }
    }

    void feed(const uint8_t* p, size_t n) {
        scanResponses(p, n);
        rxBuf.insert(rxBuf.end(), p, p + n);

        size_t pos = 0;
        for (;;) {
            size_t fi = findSync(rxBuf, pos);
            if (fi == std::string::npos) {
                pos = std::max(pos, rxBuf.size() >= 3 ? rxBuf.size() - 3 : size_t(0));
                break;
            }
            if (rxBuf.size() - fi < kFrameLen) { pos = fi; break; }
            if (crc16(&rxBuf[fi], kFrameDataLen) != be16(&rxBuf[fi + kFrameDataLen])) {
                ++nCrcErr;
                pos = fi + 1;
                continue;
            }
            Frame f;
            decodeFrame(&rxBuf[fi], f);
            pos = fi + kFrameLen;
            deliverFrame(f);
        }
        rxBuf.erase(rxBuf.begin(), rxBuf.begin() + static_cast<std::ptrdiff_t>(std::min(pos, rxBuf.size())));
        if (rxBuf.size() > (1u << 16))
            rxBuf.erase(rxBuf.begin(), rxBuf.end() - (1 << 15));
    }

    void deliverFrame(const Frame& f) {
        FrameCallback cb;
        {
            std::lock_guard<std::mutex> g(dataMutex);
            lastFrame = f;
            haveFrame = true;
            cb = frameCb;
        }
        ++nFrames;
        if (cb) cb(f);
    }

    bool command(const std::string& cmd, int timeoutMs) {
        if (!port.isOpen() || portLost) {
            setError("device not open");
            return false;
        }
        if (std::this_thread::get_id() == readerId.load()) {
            setError("commands cannot be sent from a frame callback");
            return false;
        }
        std::lock_guard<std::mutex> cg(cmdMutex);
        uint64_t before;
        {
            std::lock_guard<std::mutex> g(respMutex);
            before = respCount;
        }
        std::string line = cmd + "\r\n";
        if (!port.write(line.data(), line.size())) {
            setError("serial write failed: " + cmd);
            return false;
        }
        std::unique_lock<std::mutex> lk(respMutex);
        bool got = respCv.wait_for(lk, std::chrono::milliseconds(timeoutMs),
                                   [&] { return respCount > before || portLost.load(); });
        if (!got || respCount == before) {
            setError("no response from FPGA: " + cmd);
            return false;
        }
        if (!lastRespOk) {
            setError("FPGA replied 'Command Error!': " + cmd);
            return false;
        }
        return true;
    }

    bool command(const std::string& cmd) { return command(cmd, cmdTimeoutMs.load()); }

    void stopReader() {
        running = false;
        if (reader.joinable()) reader.join();
        readerId = std::thread::id();
    }
};

// =============================================================================
LockinDevice::LockinDevice() : d_(new Impl) {}
LockinDevice::~LockinDevice() { close(); }

std::vector<PortInfo> LockinDevice::listPorts() { return detail::SerialPort::enumerate(); }

std::string LockinDevice::findCh340Port() {
    for (const auto& p : listPorts())
        if (p.isCh340) return p.name;
    return std::string();
}

bool LockinDevice::open(const std::string& portIn, uint32_t baud) {
    close();
    std::string port = portIn.empty() ? findCh340Port() : portIn;
    if (port.empty()) {
        d_->setError("no CH340 serial port found");
        return false;
    }
    std::string err;
    if (!d_->port.open(port, baud, kReadTimeoutMs, err)) {
        d_->setError(err);
        return false;
    }
    d_->portName = port;
    d_->baud = baud;
    d_->portLost = false;
    d_->rxBuf.clear();
    d_->respTail.clear();
    {
        std::lock_guard<std::mutex> g(d_->dataMutex);
        d_->haveFrame = false;
    }
    d_->running = true;
    d_->reader = std::thread([this] { d_->readerLoop(); });
    std::this_thread::sleep_for(std::chrono::milliseconds(50));

    for (int i = 0; i < kProbeTries; ++i) {
        if (d_->command("stop", kProbeTimeoutMs)) {
            d_->streaming = false;
            d_->setError("");
            return true;
        }
    }
    d_->stopReader();
    d_->port.close();
    d_->setError("no response from FPGA on " + port +
                 " (check bitstream loaded, baud rate, and TX/RX pins L17/M17)");
    return false;
}

bool LockinDevice::setBaudRate(uint32_t baud) {
    static const uint32_t kOk[] = {
        9600u, 19200u, 38400u, 57600u, 115200u, 230400u, 460800u, 921600u};
    bool allowed = false;
    for (uint32_t b : kOk)
        if (b == baud) { allowed = true; break; }
    if (!allowed) {
        d_->setError("unsupported baud (use 9600/19200/38400/57600/115200/230400/460800/921600)");
        return false;
    }
    if (!isOpen()) {
        d_->setError("device not open");
        return false;
    }
    if (baud == d_->baud) return true;
    const bool wasStreaming = d_->streaming.load();
    if (wasStreaming) stopStream();
    if (!d_->command("BAUD:" + std::to_string(baud))) return false;
    std::string port = d_->portName;
    d_->streaming = false;
    d_->stopReader();
    d_->port.close();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if (!open(port, baud)) return false;
    if (wasStreaming) return startStream();
    return true;
}

void LockinDevice::close() {
    if (!d_->port.isOpen()) return;
    if (d_->streaming && !d_->portLost) d_->command("stop", 200);
    d_->streaming = false;
    d_->stopReader();
    d_->port.close();
    d_->respCv.notify_all();
}

bool LockinDevice::isOpen() const { return d_->port.isOpen() && !d_->portLost; }
std::string LockinDevice::portName() const { return d_->portName; }

std::string LockinDevice::lastError() const {
    std::lock_guard<std::mutex> g(d_->errMutex);
    return d_->err;
}

void LockinDevice::setCommandTimeout(int ms) { d_->cmdTimeoutMs = std::max(10, ms); }
bool LockinDevice::sendCommand(const std::string& cmd) { return d_->command(cmd); }

bool LockinDevice::setRefMode(RefMode mode) {
    return d_->command("REFMODE:" + std::to_string(static_cast<int>(mode) ? 1 : 0));
}

bool LockinDevice::setOsc1Frequency(double hz) {
    if (!(hz >= 0.0 && hz < kClockHz / 2)) {
        d_->setError("frequency out of range (0 .. 32.5 MHz)");
        return false;
    }
    return d_->command("FRQ21:" + std::to_string(hzToFreqWord(hz)));
}

bool LockinDevice::setOsc1Harmonic(int n) {
    if (n < 1 || n > 255) {
        d_->setError("harmonic must be 1..255");
        return false;
    }
    return d_->command("OHN1:" + std::to_string(n));
}

bool LockinDevice::setOsc1Coefficients(int n, int m) {
    if (n < 0 || n > 255 || m < 0 || m > 255) {
        d_->setError("coefficients n/m must be 0..255");
        return false;
    }
    return d_->command("OSC1:" + std::to_string((n << 8) | m));
}

bool LockinDevice::setOsc1Input(OscInput input) {
    int v = static_cast<int>(input);
    if (v < 0 || v > 2) {
        d_->setError("invalid oscillator input");
        return false;
    }
    return d_->command("OSRC1:" + std::to_string(v));
}

bool LockinDevice::setOsc1TimeConstant(int tau) {
    if (tau < 0 || tau > 31) {
        d_->setError("time constant (tau) must be 0..31");
        return false;
    }
    return d_->command("TAU21:" + std::to_string(tau));
}

bool LockinDevice::setOsc1FilterOrder(int order) {
    if (order < 1 || order > 4) {
        d_->setError("filter order must be 1..4");
        return false;
    }
    return d_->command("ORD21:" + std::to_string(order));
}

bool LockinDevice::setDacSourceOsc1() { return setDacSource(1); }

bool LockinDevice::setDacSource(int osc) {
    if (osc < 1 || osc > 7) {
        d_->setError("DAC source oscillator must be 1..7");
        return false;
    }
    return d_->command("DMOD:" + std::to_string(osc - 1));
}

bool LockinDevice::setDacWaveform(DacWave wave) {
    return d_->command("DWAV:" + std::to_string(wave == DacWave::Square ? 1 : 0));
}

bool LockinDevice::setDacAmplitude(double vPeak) {
    if (!(vPeak >= 0.0 && vPeak <= kDacVPeak)) {
        d_->setError("DAC amplitude out of range (0 .. 3.0 Vpk)");
        return false;
    }
    long code = std::lround(vPeak / kDacVPeak * 65535.0);
    return d_->command("DAMP:" + std::to_string(std::min(65535L, code)));
}

bool LockinDevice::setDacOffset(double volts) {
    if (!(volts >= -kDacVPeak && volts <= kDacVPeak)) {
        d_->setError("DAC offset out of range (-3.0 .. 3.0 V)");
        return false;
    }
    long code = std::lround(volts / kDacVPeak * 8191.0);
    code = std::max(-8192L, std::min(8191L, code));
    return d_->command("DOFS:" + std::to_string(code & 0x3FFF));
}

bool LockinDevice::setAdcRangeV3(AdcRange range) {
    int c = static_cast<int>(range);
    if (c < 0 || c > 11) {
        d_->setError("ADC range code must be 0..11");
        return false;
    }
    if (!d_->command("RNG3:" + std::to_string(c))) return false;
    d_->rngV3 = range;
    return true;
}

bool LockinDevice::setAdcRangeV4(AdcRange range) {
    int c = static_cast<int>(range);
    if (c < 0 || c > 11) {
        d_->setError("ADC range code must be 0..11");
        return false;
    }
    if (!d_->command("RNG4:" + std::to_string(c))) return false;
    d_->rngV4 = range;
    return true;
}

AdcRange LockinDevice::adcRangeV3() const { return d_->rngV3; }
AdcRange LockinDevice::adcRangeV4() const { return d_->rngV4; }

bool LockinDevice::startStream() {
    if (!d_->command("SDKOUT")) return false;
    d_->streaming = true;
    return true;
}

bool LockinDevice::stopStream() {
    if (!d_->command("stop")) return false;
    d_->streaming = false;
    return true;
}

bool LockinDevice::isStreaming() const { return d_->streaming.load(); }

void LockinDevice::setFrameCallback(FrameCallback cb) {
    std::lock_guard<std::mutex> g(d_->dataMutex);
    d_->frameCb = std::move(cb);
}

bool LockinDevice::latestFrame(Frame& out) const {
    std::lock_guard<std::mutex> g(d_->dataMutex);
    if (!d_->haveFrame) return false;
    out = d_->lastFrame;
    return true;
}

uint64_t LockinDevice::framesReceived() const { return d_->nFrames.load(); }
uint64_t LockinDevice::crcErrors() const { return d_->nCrcErr.load(); }

}  // namespace lockin_osc1
