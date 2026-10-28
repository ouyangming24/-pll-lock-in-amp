// =============================================================================
// Lock-In Amplifier C++ SDK  (板载 CH340 串口, 921600 8N1)
//
// 功能:
//   - 振荡器 1..7 (通道3 PSD 参考) 频率 / 谐波 / 系数 / 输入源 / 滤波
//   - DAC904 信号输出 (源振荡器 / 波形 / 幅值 / 偏置)
//   - 示波器: AD7606C V5 / V6 两路波形 (1024 点, 最高 1 MSPS, 可触发)
//   - 数据流: 锁相结果帧 (X/Y/R/θ、参考频率、PLL 频率、锁定标志)
//
// 线程模型:
//   open() 后 SDK 内部有一个接收线程, 负责解析 FPGA 上行字节流 (命令应答 /
//   数据帧 / 示波器包). 所有公有方法都是线程安全的.
//   FrameCallback / ScopeCallback 在接收线程里被调用, 回调里不要做耗时操作,
//   也不要在回调里调用 setXxx() / sendCommand() / captureScope() (会直接失败).
//
// 协议见 README.md 与 FPGA usb_commend.v.
// =============================================================================
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#if defined(_WIN32) && defined(LOCKIN_SDK_SHARED)
#  if defined(LOCKIN_SDK_EXPORTS)
#    define LOCKIN_API __declspec(dllexport)
#  else
#    define LOCKIN_API __declspec(dllimport)
#  endif
#else
#  define LOCKIN_API
#endif

namespace lockin {

// ---------------------------------------------------------------------------
// 硬件常量
// ---------------------------------------------------------------------------
constexpr double   kClockHz        = 65e6;           // DDS 时钟
constexpr int      kPhaseBits      = 48;             // DDS 相位累加器位宽
constexpr int      kNumOsc         = 7;              // 振荡器个数 (1..7)
constexpr uint32_t kDefaultBaud    = 921600;
constexpr double   kDacVPeak       = 3.0;            // DAC904 峰值满量程 (V)
constexpr double   kScopeAdcHz     = 1e6;            // 示波器原始采样率 (AD7606C)
constexpr double   kScopeVPerLsb   = 10.0 / 32768.0; // 示波器码值 → V (±10 V 量程)
constexpr double   kIirFsHz        = 1e6;            // 解调 IIR 采样率 (TAU 换算用)

// ---------------------------------------------------------------------------
// 枚举
// ---------------------------------------------------------------------------
enum class RefMode : int {
    Manual = 0,   // 参考频率 = setOscFrequency() × 谐波次数 N   (各振荡器独立 DDS)
    Auto   = 1,   // 参考频率 = N × (n·F1 + m·F2), F1/F2 来自通道1/2 PLL
};

enum class OscInput : int {
    CH3          = 0,
    CH4          = 1,
    CH3_minus_CH4 = 2,
};

enum class DacWave : int {
    Sine   = 0,
    Square = 1,
};

enum class ScopeTrigger : int {
    Free      = 0,   // 不等触发, 立即抓
    V5Rising  = 1,
    V5Falling = 2,
    V6Rising  = 3,
    V6Falling = 4,
};

// ---------------------------------------------------------------------------
// 串口信息
// ---------------------------------------------------------------------------
struct PortInfo {
    std::string name;          // "COM5"
    std::string description;   // "USB-SERIAL CH340 (COM5)"  (UTF-8)
    bool        isCh340 = false;
};

// ---------------------------------------------------------------------------
// 示波器
// ---------------------------------------------------------------------------
struct ScopeConfig {
    uint16_t     decimation = 0;     // 每 (decimation+1) 个 ADC 样点取 1 点; dt = (decimation+1) µs
    ScopeTrigger trigger    = ScopeTrigger::Free;
    double       levelVolts = 0.0;   // 触发电平 (V, ±10)
    bool         normalMode = false; // false = Auto (无触发时 FPGA 超时强制抓一屏)
                                     // true  = Normal (一直等触发)
};

struct ScopeData {
    uint32_t     seq        = 0;     // FPGA 包序号
    uint16_t     n          = 0;     // 点数 (1024)
    uint16_t     pre        = 0;     // 触发前点数 (128), 触发点 = 下标 pre
    uint16_t     decimation = 0;
    ScopeTrigger trigger    = ScopeTrigger::Free;
    bool         forced     = false; // true: Auto 模式超时强制触发 (并未真正触发)
    double       dt         = 0.0;   // 采样间隔 (s)

    std::vector<int16_t> v5Raw, v6Raw;   // 原始码值
    std::vector<double>  v5, v6;         // 电压 (V)

    // 第 i 点相对触发点的时间 (s), 触发点为 0
    double timeAt(size_t i) const { return (static_cast<double>(i) - pre) * dt; }
    std::vector<double> timeAxis() const;
};

// ---------------------------------------------------------------------------
// 数据帧 (XYOUT 数据流, 约 450 帧/s)
// 振荡器下标一律 1..7
// ---------------------------------------------------------------------------
struct Frame {
    int32_t  ch1X = 0, ch1Y = 0, ch2X = 0, ch2Y = 0;  // 通道1/2 PLL 鉴相 X/Y
    int32_t  oscX[kNumOsc] = {}, oscY[kNumOsc] = {}; // 振荡器1..7 解调 X/Y 原始码值
    int32_t  ch3Dc = 0;
    int32_t  adc[3] = {};
    uint64_t pllWord[2] = {};                        // 通道1/2 PLL 频率字
    int32_t  lockFlags = 0;                          // bit0 = 通道1锁定, bit1 = 通道2锁定
    uint64_t refWord[kNumOsc] = {};                  // 振荡器1..7 实际生效的参考频率字
    uint32_t sampleCount = 0;                        // FPGA 1 MHz 时间戳
    uint32_t frameSeq = 0;

    double oscXVolts(int osc) const;      // 峰值电压 (V)
    double oscYVolts(int osc) const;
    double oscRVolts(int osc) const;      // R = sqrt(X²+Y²), 峰值; 有效值 = R/√2
    double oscPhaseDeg(int osc) const;    // atan2(Y, X), 度
    double oscRefHz(int osc) const;       // 振荡器参考频率 (Hz)
    double pllHz(int ch) const;           // ch = 1 / 2
    double ch3DcVolts() const;
    bool   ch1Locked() const { return (lockFlags & 1) != 0; }
    bool   ch2Locked() const { return (lockFlags & 2) != 0; }
};

using FrameCallback = std::function<void(const Frame&)>;
using ScopeCallback = std::function<void(const ScopeData&)>;

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------
LOCKIN_API uint64_t hzToFreqWord(double hz);
LOCKIN_API double   freqWordToHz(uint64_t word);
LOCKIN_API double   tauToCutoffHz(int tau);     // TAU (0..31) → -3 dB 截止频率 (一阶)
LOCKIN_API double   tauToSeconds(int tau);      // TAU → 等效时间常数 1/(2π·fc)

// X/Y 原始码值 → 峰值电压 的系数 (与上位机 GUI 一致, 可按实测标定修改)
LOCKIN_API double   voltsPerLsb();
LOCKIN_API void     setVoltsPerLsb(double v);
LOCKIN_API double   voltsPerLsbDc();
LOCKIN_API void     setVoltsPerLsbDc(double v);

// ---------------------------------------------------------------------------
// 设备
// ---------------------------------------------------------------------------
class LOCKIN_API LockinDevice {
public:
    LockinDevice();
    ~LockinDevice();
    LockinDevice(const LockinDevice&) = delete;
    LockinDevice& operator=(const LockinDevice&) = delete;

    // ---- 连接 -------------------------------------------------------------
    static std::vector<PortInfo> listPorts();   // CH340 排在最前
    static std::string findCh340Port();         // 找不到返回 ""

    // 打开串口并发 "stop" 握手确认 FPGA 有应答; port 为空时自动找 CH340
    bool open(const std::string& port = "", uint32_t baud = kDefaultBaud);
    void close();
    bool isOpen() const;
    std::string portName() const;

    std::string lastError() const;

    // 命令应答超时 (默认 500 ms)
    void setCommandTimeout(int ms);

    // 原始命令, 如 "FRQ21:4331753328", 不带换行; FPGA 回 "Command Success!" 返回 true
    bool sendCommand(const std::string& cmd);

    // 时基标定系数 k = 实测频率 / 设定频率 (板上晶振偏差), 默认 1.0;
    // setOscFrequency 下发时按 hz / k 换算, 使物理输出等于设定值
    void   setClockCalibration(double k);
    double clockCalibration() const;

    // ---- 振荡器 (osc = 1..7) ----------------------------------------------
    // 全局参考模式 (对 7 个振荡器同时生效), 上电默认 Manual
    bool setRefMode(RefMode mode);
    // Manual 模式下的基准频率 (Hz, 0 < hz < 32.5 MHz); 实际参考频率 = hz × 谐波次数
    bool setOscFrequency(int osc, double hz);
    // 谐波次数 N (1..255)
    bool setOscHarmonic(int osc, int n);
    // Auto 模式系数: 参考频率 = N × (n·F1 + m·F2), n/m = 0..255
    bool setOscCoefficients(int osc, int n, int m);
    // 解调输入源
    bool setOscInput(int osc, OscInput input);
    // 低通时间常数档位 0..31 (越大越慢), 换算见 tauToCutoffHz()
    bool setOscTimeConstant(int osc, int tau);
    // 低通阶数 1..4
    bool setOscFilterOrder(int osc, int order);

    // ---- DAC 输出 ---------------------------------------------------------
    // 输出 = 所选振荡器的参考正弦 (频率 = 该振荡器参考频率) × 幅值 + 偏置
    bool setDacSource(int osc);                 // 1..7
    bool setDacWaveform(DacWave wave);
    bool setDacAmplitude(double vPeak);         // 0 ~ 3.0 Vpk
    bool setDacOffset(double volts);            // -3.0 ~ +3.0 V

    // ---- 示波器 V5 / V6 ---------------------------------------------------
    // 阻塞抓一屏; timeoutMs 内无数据返回 false. 不需要先 startStream().
    bool captureScope(ScopeData& out, const ScopeConfig& cfg = ScopeConfig(),
                      int timeoutMs = 3000);
    // 非阻塞: 下发配置并启动一次抓取, 结果通过 ScopeCallback 送出
    bool armScope(const ScopeConfig& cfg = ScopeConfig());
    void setScopeCallback(ScopeCallback cb);

    // ---- 数据流 -----------------------------------------------------------
    bool startStream();                         // 发 XYOUT
    bool stopStream();                          // 发 stop
    bool isStreaming() const;
    void setFrameCallback(FrameCallback cb);
    // 最近一帧; 尚未收到帧返回 false
    bool latestFrame(Frame& out) const;

    // ---- 统计 -------------------------------------------------------------
    uint64_t framesReceived() const;
    uint64_t scopesReceived() const;
    uint64_t crcErrors() const;                 // 数据帧 + 示波器包 CRC 错误总数

private:
    struct Impl;
    std::unique_ptr<Impl> d_;
};

}  // namespace lockin
