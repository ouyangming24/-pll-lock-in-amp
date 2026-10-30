#include "lockin/lockin_sdk.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>

#include "serial_port.h"

namespace lockin {

// =============================================================================
// 协议常量 (与 usb_commend.v / lockin_gui/device.py 一致)
// =============================================================================
namespace {

constexpr uint8_t kFrameSync[4] = {0xA5, 0x5A, 0xA5, 0x5A};
constexpr uint8_t kScopeSync[4] = {0xA5, 0x5A, 0x5A, 0xA5};
constexpr size_t  kFrameLen     = 178;              // 4 sync + 172 数据 + 2 CRC
constexpr size_t  kFrameDataLen = kFrameLen - 2;    // CRC 覆盖范围 (含同步头)
constexpr size_t  kScopeHdrLen  = 16;
constexpr uint16_t kScopeMaxN   = 8192;

constexpr const char* kRespOk  = "Command Success!";
constexpr const char* kRespErr = "Command Error!";
constexpr size_t kRespMaxLen   = 16;

constexpr double kPi = 3.14159265358979323846;

constexpr int kReadTimeoutMs   = 20;
constexpr int kProbeTries      = 3;
constexpr int kProbeTimeoutMs  = 300;

// 振荡器 1..7 → 命令名 (振荡器1/2/3 沿用历史命名 21/12/11)
const char* const kFrqCmd[kNumOsc] = {"FRQ21", "FRQ12", "FRQ11", "FRQ4", "FRQ5", "FRQ6", "FRQ7"};
const char* const kTauCmd[kNumOsc] = {"TAU21", "TAU12", "TAU11", "TAU4", "TAU5", "TAU6", "TAU7"};
const char* const kOrdCmd[kNumOsc] = {"ORD21", "ORD12", "ORD11", "ORD4", "ORD5", "ORD6", "ORD7"};

// 码值 → 电压 (与 GUI main_window.py 相同的推导)
//   G_TOTAL = (2^13 / 9.75) × 2^13 × 0.5 × CIC_GAIN_EFF,  CIC_GAIN_EFF = 65^5 / 2^31
const double kCicGainEff = std::pow(65.0, 5) / 2147483648.0;
const double kGTotal     = (8192.0 / 9.75) * 8192.0 * 0.5 * kCicGainEff;
const double kGDc        = (8192.0 / 9.75) * kCicGainEff;
std::atomic<double> g_vPerLsb{0.9966 / kGTotal};
std::atomic<double> g_vPerLsbDc{1.0 / kGDc};

// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF (= Python binascii.crc_hqx(data, 0xFFFF))
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
uint64_t be64(const uint8_t* p) {
    return (static_cast<uint64_t>(be32(p)) << 32) | be32(p + 4);
}

size_t findSync(const std::vector<uint8_t>& b, size_t from, const uint8_t (&sync)[4]) {
    if (b.size() < 4) return std::string::npos;
    for (size_t i = from; i + 4 <= b.size(); ++i)
        if (b[i] == sync[0] && b[i + 1] == sync[1] && b[i + 2] == sync[2] && b[i + 3] == sync[3])
            return i;
    return std::string::npos;
}

bool validOsc(int osc) { return osc >= 1 && osc <= kNumOsc; }

void decodeFrame(const uint8_t* p, Frame& f) {
    p += 4;
    auto i32 = [&p]() { int32_t v = static_cast<int32_t>(be32(p)); p += 4; return v; };
    auto u32 = [&p]() { uint32_t v = be32(p); p += 4; return v; };
    auto u64 = [&p]() { uint64_t v = be64(p); p += 8; return v; };
    f.ch1X = i32(); f.ch1Y = i32();
    f.ch2X = i32(); f.ch2Y = i32();
    for (int k = 0; k < kNumOsc; ++k) { f.oscX[k] = i32(); f.oscY[k] = i32(); }
    f.ch3Dc = i32();
    for (int k = 0; k < 3; ++k) f.adc[k] = i32();
    f.pllWord[0] = u64(); f.pllWord[1] = u64();
    f.lockFlags = i32();
    for (int k = 0; k < kNumOsc; ++k) f.refWord[k] = u64();
    f.sampleCount = u32();
    f.frameSeq = u32();
}

void decodeScope(const uint8_t* p, ScopeData& s) {
    s.n          = be16(p + 4);
    s.pre        = be16(p + 6);
    s.decimation = be16(p + 8);
    uint8_t flags = p[10];
    s.forced     = (flags & 1) != 0;
    s.trigger    = static_cast<ScopeTrigger>((flags >> 1) & 0x7);
    s.seq        = be32(p + 12);
    s.dt         = (s.decimation + 1.0) / kScopeAdcHz;
    s.v5Raw.resize(s.n); s.v6Raw.resize(s.n);
    s.v5.resize(s.n);    s.v6.resize(s.n);
    const uint8_t* d = p + kScopeHdrLen;
    for (size_t i = 0; i < s.n; ++i, d += 4) {
        s.v5Raw[i] = static_cast<int16_t>(be16(d));
        s.v6Raw[i] = static_cast<int16_t>(be16(d + 2));
        s.v5[i] = s.v5Raw[i] * kScopeVPerLsb;
        s.v6[i] = s.v6Raw[i] * kScopeVPerLsb;
    }
}

}  // namespace

// =============================================================================
// 工具函数
// =============================================================================
uint64_t hzToFreqWord(double hz) {
    long long w = std::llround(hz * std::ldexp(1.0, kPhaseBits) / kClockHz);
    if (w < 0) w = 0;
    return static_cast<uint64_t>(w) & ((uint64_t(1) << kPhaseBits) - 1);
}

double freqWordToHz(uint64_t word) {
    return static_cast<double>(word) * kClockHz / std::ldexp(1.0, kPhaseBits);
}

double tauToCutoffHz(int tau) {
    if (tau <= 0) return INFINITY;
    double alpha = std::ldexp(1.0, -tau);
    double sinHalf = alpha / (2.0 * std::sqrt(1.0 - alpha));
    double cosHalf = std::sqrt(std::max(0.0, 1.0 - sinHalf * sinHalf));
    double omega = 2.0 * std::atan2(sinHalf, cosHalf);
    return omega * kIirFsHz / (2.0 * kPi);
}

double tauToSeconds(int tau) {
    if (tau <= 0) return 0.0;
    return 1.0 / (2.0 * kPi * tauToCutoffHz(tau));
}

double voltsPerLsb() { return g_vPerLsb.load(); }
void   setVoltsPerLsb(double v) { g_vPerLsb.store(v); }
double voltsPerLsbDc() { return g_vPerLsbDc.load(); }
void   setVoltsPerLsbDc(double v) { g_vPerLsbDc.store(v); }

std::vector<double> ScopeData::timeAxis() const {
    std::vector<double> t(n);
    for (size_t i = 0; i < n; ++i) t[i] = timeAt(i);
    return t;
}

double Frame::oscXVolts(int osc) const { return validOsc(osc) ? oscX[osc - 1] * voltsPerLsb() : 0.0; }
double Frame::oscYVolts(int osc) const { return validOsc(osc) ? oscY[osc - 1] * voltsPerLsb() : 0.0; }
double Frame::oscRVolts(int osc) const { return std::hypot(oscXVolts(osc), oscYVolts(osc)); }
double Frame::oscPhaseDeg(int osc) const {
    if (!validOsc(osc)) return 0.0;
    return std::atan2(static_cast<double>(oscY[osc - 1]), static_cast<double>(oscX[osc - 1])) * 180.0 / kPi;
}
double Frame::oscRefHz(int osc) const { return validOsc(osc) ? freqWordToHz(refWord[osc - 1]) : 0.0; }
double Frame::pllHz(int ch) const { return (ch == 1 || ch == 2) ? freqWordToHz(pllWord[ch - 1]) : 0.0; }
double Frame::ch3DcVolts() const { return ch3Dc * voltsPerLsbDc(); }

// =============================================================================
// LockinDevice::Impl
// =============================================================================
struct LockinDevice::Impl {
    detail::SerialPort port;
    std::string portName;
    uint32_t baud = kDefaultBaud;
    AdcRange rngV3 = AdcRange::Bipolar10V;
    AdcRange rngV4 = AdcRange::Bipolar10V;

    // 接收线程
    std::thread reader;
    std::atomic<bool> running{false};
    std::atomic<bool> portLost{false};
    std::atomic<std::thread::id> readerId{std::thread::id()};
    std::vector<uint8_t> rxBuf;
    std::string respTail;

    // 命令串行化 + 应答
    std::mutex cmdMutex;
    std::mutex respMutex;
    std::condition_variable respCv;
    uint64_t respCount = 0;
    bool lastRespOk = false;
    std::atomic<int> cmdTimeoutMs{500};

    // 帧 / 示波器
    mutable std::mutex dataMutex;
    std::condition_variable scopeCv;
    Frame lastFrame;
    bool haveFrame = false;
    ScopeData lastScope;
    uint64_t scopeCount = 0;
    FrameCallback frameCb;
    ScopeCallback scopeCb;
    std::atomic<uint64_t> nFrames{0}, nScopes{0}, nCrcErr{0};

    std::atomic<bool> streaming{false};
    std::atomic<double> clkCal{1.0};

    mutable std::mutex errMutex;
    std::string err;

    void setError(const std::string& e) {
        std::lock_guard<std::mutex> g(errMutex);
        err = e;
    }

    // ---- 接收线程 ----------------------------------------------------------
    void readerLoop() {
        readerId = std::this_thread::get_id();
        uint8_t tmp[4096];
        while (running.load()) {
            int n = port.read(tmp, sizeof(tmp));
            if (n < 0) {
                portLost = true;
                setError("serial port read failed (device unplugged?)");
                respCv.notify_all();
                scopeCv.notify_all();
                break;
            }
            if (n > 0) feed(tmp, static_cast<size_t>(n));
        }
    }

    // 命令应答是 ASCII, 与二进制包交错出现在同一字节流里, 单独扫描
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
            size_t fi = findSync(rxBuf, pos, kFrameSync);
            size_t si = findSync(rxBuf, pos, kScopeSync);
            if (si != std::string::npos && (fi == std::string::npos || si < fi)) {
                if (rxBuf.size() - si < kScopeHdrLen) { pos = si; break; }
                uint16_t sn = be16(&rxBuf[si + 4]), spre = be16(&rxBuf[si + 6]);
                if (sn < 16 || sn > kScopeMaxN || (sn & (sn - 1)) || spre >= sn) { pos = si + 1; continue; }
                size_t need = kScopeHdrLen + 4u * sn + 2;
                if (rxBuf.size() - si < need) { pos = si; break; }
                if (crc16(&rxBuf[si], need - 2) != be16(&rxBuf[si + need - 2])) {
                    ++nCrcErr;
                    pos = si + 1;
                    continue;
                }
                ScopeData sd;
                decodeScope(&rxBuf[si], sd);
                pos = si + need;
                deliverScope(std::move(sd));
                continue;
            }
            if (fi == std::string::npos) {
                pos = std::max(pos, rxBuf.size() >= 3 ? rxBuf.size() - 3 : size_t(0));
                break;
            }
            if (rxBuf.size() - fi < kFrameLen) { pos = fi; break; }
            if (crc16(&rxBuf[fi], kFrameDataLen) != be16(&rxBuf[fi + kFrameDataLen])) {
                // 半帧 (被命令打断) 或误码: 只跳过这个同步头
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

    void deliverScope(ScopeData&& s) {
        ScopeCallback cb;
        {
            std::lock_guard<std::mutex> g(dataMutex);
            lastScope = std::move(s);
            ++scopeCount;
            cb = scopeCb;
        }
        ++nScopes;
        scopeCv.notify_all();
        if (cb) {
            ScopeData copy;
            {
                std::lock_guard<std::mutex> g(dataMutex);
                copy = lastScope;
            }
            cb(copy);
        }
    }

    // ---- 命令 --------------------------------------------------------------
    bool command(const std::string& cmd, int timeoutMs) {
        if (!port.isOpen() || portLost) {
            setError("device not open");
            return false;
        }
        if (std::this_thread::get_id() == readerId.load()) {
            setError("commands cannot be sent from a frame/scope callback");
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

    bool scopeSetup(const ScopeConfig& cfg) {
        if (cfg.levelVolts < -10.0 || cfg.levelVolts > 10.0) {
            setError("scope trigger level out of range (-10..10 V)");
            return false;
        }
        int t = static_cast<int>(cfg.trigger);
        if (t < 0 || t > 4) {
            setError("invalid scope trigger");
            return false;
        }
        long code = std::lround(cfg.levelVolts / kScopeVPerLsb);
        code = std::max(-32768L, std::min(32767L, code));
        return command("SDEC:" + std::to_string(cfg.decimation)) &&
               command("STLV:" + std::to_string(code + 32768));
    }

    static int scopeModeWord(const ScopeConfig& cfg) {
        return static_cast<int>(cfg.trigger) | (cfg.normalMode ? 8 : 0);
    }

    void stopReader() {
        running = false;
        if (reader.joinable()) reader.join();
        readerId = std::thread::id();
    }
};

// =============================================================================
// LockinDevice
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

    // stop 握手: 既确认 FPGA 在线, 也关掉可能残留的数据流
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
    d_->respCv.notify_all();
    d_->scopeCv.notify_all();
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
    d_->scopeCv.notify_all();
}

bool LockinDevice::isOpen() const { return d_->port.isOpen() && !d_->portLost; }

std::string LockinDevice::portName() const { return d_->portName; }

std::string LockinDevice::lastError() const {
    std::lock_guard<std::mutex> g(d_->errMutex);
    return d_->err;
}

void LockinDevice::setCommandTimeout(int ms) { d_->cmdTimeoutMs = std::max(10, ms); }

bool LockinDevice::sendCommand(const std::string& cmd) { return d_->command(cmd); }

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

void LockinDevice::setClockCalibration(double k) {
    if (k > 0.9 && k < 1.1) d_->clkCal = k;
}

double LockinDevice::clockCalibration() const { return d_->clkCal.load(); }

// ---- 振荡器 -----------------------------------------------------------------
#define LOCKIN_CHECK_OSC(osc)                                     \
    do {                                                          \
        if (!validOsc(osc)) {                                     \
            d_->setError("oscillator index must be 1..7");       \
            return false;                                         \
        }                                                         \
    } while (0)

bool LockinDevice::setRefMode(RefMode mode) {
    return d_->command("REFMODE:" + std::to_string(static_cast<int>(mode) ? 1 : 0));
}

bool LockinDevice::setOscFrequency(int osc, double hz) {
    LOCKIN_CHECK_OSC(osc);
    if (!(hz >= 0.0 && hz < kClockHz / 2)) {
        d_->setError("frequency out of range (0 .. 32.5 MHz)");
        return false;
    }
    uint64_t word = hzToFreqWord(hz / d_->clkCal.load());
    return d_->command(std::string(kFrqCmd[osc - 1]) + ":" + std::to_string(word));
}

bool LockinDevice::setOscHarmonic(int osc, int n) {
    LOCKIN_CHECK_OSC(osc);
    if (n < 1 || n > 255) {
        d_->setError("harmonic must be 1..255");
        return false;
    }
    return d_->command("OHN" + std::to_string(osc) + ":" + std::to_string(n));
}

bool LockinDevice::setOscCoefficients(int osc, int n, int m) {
    LOCKIN_CHECK_OSC(osc);
    if (n < 0 || n > 255 || m < 0 || m > 255) {
        d_->setError("coefficients n/m must be 0..255");
        return false;
    }
    return d_->command("OSC" + std::to_string(osc) + ":" + std::to_string((n << 8) | m));
}

bool LockinDevice::setOscInput(int osc, OscInput input) {
    LOCKIN_CHECK_OSC(osc);
    int v = static_cast<int>(input);
    if (v < 0 || v > 2) {
        d_->setError("invalid oscillator input");
        return false;
    }
    return d_->command("OSRC" + std::to_string(osc) + ":" + std::to_string(v));
}

bool LockinDevice::setOscTimeConstant(int osc, int tau) {
    LOCKIN_CHECK_OSC(osc);
    if (tau < 0 || tau > 31) {
        d_->setError("time constant (tau) must be 0..31");
        return false;
    }
    return d_->command(std::string(kTauCmd[osc - 1]) + ":" + std::to_string(tau));
}

bool LockinDevice::setOscFilterOrder(int osc, int order) {
    LOCKIN_CHECK_OSC(osc);
    if (order < 1 || order > 4) {
        d_->setError("filter order must be 1..4");
        return false;
    }
    return d_->command(std::string(kOrdCmd[osc - 1]) + ":" + std::to_string(order));
}

// ---- DAC --------------------------------------------------------------------
bool LockinDevice::setDacSource(int osc) {
    LOCKIN_CHECK_OSC(osc);
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

#undef LOCKIN_CHECK_OSC

// ---- 示波器 -----------------------------------------------------------------
bool LockinDevice::armScope(const ScopeConfig& cfg) {
    return d_->scopeSetup(cfg) && d_->command("SCAP:" + std::to_string(Impl::scopeModeWord(cfg)));
}

void LockinDevice::setScopeCallback(ScopeCallback cb) {
    std::lock_guard<std::mutex> g(d_->dataMutex);
    d_->scopeCb = std::move(cb);
}

bool LockinDevice::captureScope(ScopeData& out, const ScopeConfig& cfg, int timeoutMs) {
    using clock = std::chrono::steady_clock;
    uint64_t start;
    {
        std::lock_guard<std::mutex> g(d_->dataMutex);
        start = d_->scopeCount;
    }
    if (!d_->scopeSetup(cfg)) return false;
    const std::string scap = "SCAP:" + std::to_string(Impl::scopeModeWord(cfg));
    if (!d_->command(scap)) return false;

    // 示波器包偶尔因误码被 CRC 丢掉: 超时没收到就重发 SCAP (同 GUI 的 watchdog)
    const double windowMs = 1024.0 * (cfg.decimation + 1) / kScopeAdcHz * 1000.0;
    const auto rearmEvery = std::chrono::milliseconds(
        static_cast<long long>((cfg.normalMode ? 3000.0 : 1000.0) + 3.0 * windowMs));
    const auto deadline = clock::now() + std::chrono::milliseconds(timeoutMs);
    auto nextRearm = clock::now() + rearmEvery;

    for (;;) {
        {
            std::unique_lock<std::mutex> lk(d_->dataMutex);
            auto until = std::min(deadline, nextRearm);
            d_->scopeCv.wait_until(lk, until, [&] {
                return d_->portLost.load() ||
                       (d_->scopeCount > start &&
                        d_->lastScope.decimation == cfg.decimation &&
                        d_->lastScope.trigger == cfg.trigger);
            });
            if (d_->portLost) return false;
            if (d_->scopeCount > start && d_->lastScope.decimation == cfg.decimation &&
                d_->lastScope.trigger == cfg.trigger) {
                out = d_->lastScope;
                return true;
            }
            // 收到的是旧配置的包, 不算
            start = d_->scopeCount;
        }
        auto now = clock::now();
        if (now >= deadline) {
            d_->setError("scope capture timeout (no trigger?)");
            return false;
        }
        if (now >= nextRearm) {
            if (!d_->command(scap)) return false;
            nextRearm = now + rearmEvery;
        }
    }
}

// ---- 数据流 -----------------------------------------------------------------
bool LockinDevice::startStream() {
    if (!d_->command("XYOUT")) return false;
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
uint64_t LockinDevice::scopesReceived() const { return d_->nScopes.load(); }
uint64_t LockinDevice::crcErrors() const { return d_->nCrcErr.load(); }

}  // namespace lockin
