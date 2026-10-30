// =============================================================================
// Lock-In Osc1 Stream SDK  (板载 CH340, 默认 115200 8N1, BAUD: 可调)
//
// 与经典 lockin_sdk_cpp / GUI 并存:
//   - GUI 仍用 XYOUT (178 字节全量帧) + SCAP 1024 点示波器包
//   - 本 SDK 用 SDKOUT: 每帧 28 字节 = 振荡器1 X/Y + V3/V4/V5 瞬时样点
//
// 控制能力: 振荡器1 (频率/谐波/系数/输入/滤波) + DAC + REFMODE
// 数据流: startStream() → SDKOUT; 无 1024 点示波器抓取 API
// =============================================================================
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace lockin_osc1 {

constexpr double   kClockHz      = 65e6;
constexpr int      kPhaseBits    = 48;
constexpr uint32_t kDefaultBaud  = 115200;
constexpr double   kDacVPeak     = 3.0;
constexpr double   kAdcVPerLsb16 = 10.0 / 32768.0;  // ±10 V 默认, 16 bit
constexpr double   kIirFsHz      = 1e6;

enum class RefMode : int { Manual = 0, Auto = 1 };
enum class OscInput : int { CH3 = 0, CH4 = 1, CH3_minus_CH4 = 2 };
enum class DacWave : int { Sine = 0, Square = 1 };

// AD7606C 软件量程码 (RNG3/RNG4), 与数据手册一致
enum class AdcRange : int {
    Bipolar2V5 = 0,   // ±2.5 V 单端
    Bipolar5V  = 1,   // ±5 V
    Bipolar6V25= 2,   // ±6.25 V
    Bipolar10V = 3,   // ±10 V (上电默认)
    Bipolar12V5= 4,   // ±12.5 V
};

double adcRangePeakVolts(AdcRange r);  // 双极单端满量程峰值; 其它码返回 0

struct PortInfo {
    std::string name;
    std::string description;
    bool        isCh340 = false;
};

// SDKOUT 一帧 (约 2 kHz 量级, 受串口带宽限制; FPGA 侧按 1 MSPS 刷新快照)
struct Frame {
    int32_t  osc1X = 0, osc1Y = 0;   // 振荡器1 解调原始码
    int16_t  v3 = 0, v4 = 0, v5 = 0; // AD7606C 原始码 (示波器用瞬时值, 非攒包)
    uint32_t sampleCount = 0;
    uint32_t frameSeq    = 0;

    double osc1XVolts() const;
    double osc1YVolts() const;
    double osc1RVolts() const;
    double osc1PhaseDeg() const;
    double v3Volts(AdcRange range = AdcRange::Bipolar10V) const;
    double v4Volts(AdcRange range = AdcRange::Bipolar10V) const;
    double v5Volts() const { return v5 * kAdcVPerLsb16; }  // V5 量程暂固定 ±10 V
};

using FrameCallback = std::function<void(const Frame&)>;

uint64_t hzToFreqWord(double hz);
double   freqWordToHz(uint64_t word);
double   voltsPerLsb();          // 解调 X/Y → V (与 GUI 默认同)
void     setVoltsPerLsb(double v);

class LockinDevice {
public:
    LockinDevice();
    ~LockinDevice();
    LockinDevice(const LockinDevice&) = delete;
    LockinDevice& operator=(const LockinDevice&) = delete;

    static std::vector<PortInfo> listPorts();
    static std::string findCh340Port();

    bool open(const std::string& port = "", uint32_t baud = kDefaultBaud);
    void close();
    bool isOpen() const;
    std::string portName() const;
    std::string lastError() const;
    void setCommandTimeout(int ms);

    bool sendCommand(const std::string& cmd);

    // 切换 FPGA + 本端波特率 (允许: 9600..921600 预设档). 会停流并重开串口.
    bool setBaudRate(uint32_t baud);

    bool setRefMode(RefMode mode);
    bool setOsc1Frequency(double hz);
    bool setOsc1Harmonic(int n);
    bool setOsc1Coefficients(int n, int m);
    bool setOsc1Input(OscInput input);
    bool setOsc1TimeConstant(int tau);
    bool setOsc1FilterOrder(int order);

    bool setDacSourceOsc1();                 // DMOD:0
    bool setDacSource(int osc /*1..7*/);
    bool setDacWaveform(DacWave wave);
    bool setDacAmplitude(double vPeak);
    bool setDacOffset(double volts);

    // AD7606C V3/V4 量程 (RNG3/RNG4). 成功后本地也记住, 供 v3Volts/v4Volts 默认换算.
    bool setAdcRangeV3(AdcRange range);
    bool setAdcRangeV4(AdcRange range);
    AdcRange adcRangeV3() const;
    AdcRange adcRangeV4() const;

    bool startStream();   // SDKOUT
    bool stopStream();    // stop
    bool isStreaming() const;
    void setFrameCallback(FrameCallback cb);
    bool latestFrame(Frame& out) const;

    uint64_t framesReceived() const;
    uint64_t crcErrors() const;

private:
    struct Impl;
    std::unique_ptr<Impl> d_;
};

}  // namespace lockin_osc1
