# Lock-In Amplifier C++ SDK

通过板载 CH340 串口 (PL 端 L17/M17, 921600 8N1) 控制锁相放大器 FPGA:

- 振荡器 1..7 (常用 1、2): 频率、谐波次数、自动模式系数、输入源、低通时间常数/阶数
- DAC904 输出: 源振荡器、正弦/方波、幅值 (Vpk)、直流偏置
- 示波器: V5 / V6 两路波形 (1024 点, 最高 1 MSPS, 触发可选)
- 数据流: 各振荡器解调结果 X/Y/R/θ、参考频率、PLL 频率与锁定状态 (约 450 帧/s)

仅依赖 Win32 API + C++17 标准库, 无第三方库.

## 目录

```
lockin_sdk_cpp/
  include/lockin/lockin_sdk.h   公开头文件 (唯一需要 include 的文件)
  src/lockin_sdk.cpp            协议 / 解析 / API 实现
  src/serial_port.h, serial_port_win.cpp   Win32 串口 (重叠 I/O)
  examples/demo.cpp             示例: 配振荡器 → DAC → 抓 V5/V6 存 CSV → 读数据流
  tests/sdk_selftest.cpp        自测程序 (配合 fake_fpga.py)
  tests/fake_fpga.py            模拟 FPGA 串口端, 无板子时测试用
  CMakeLists.txt
  build_mingw.bat               不用 CMake 时用 MinGW g++ 直接编译
```

## 集成到工程

三选一:

1. **直接加源码 (最简单)**: 把 `include/` 加到包含目录, 把 `src/*.cpp` 加入工程,
   语言标准选 C++17, 链接 `setupapi.lib` (MSVC 下源码里已有 `#pragma comment`, 无需手动加).
   MSVC 建议加编译选项 `/utf-8` (源码注释为 UTF-8).
2. **CMake**: `add_subdirectory(lockin_sdk_cpp)` 后 `target_link_libraries(你的目标 PRIVATE lockin::sdk)`.
   单独编译: `cmake -B build -G "Visual Studio 17 2022" && cmake --build build --config Release`.
   `-DLOCKIN_BUILD_SHARED=ON` 可编成 DLL.
3. **MinGW**: 运行 `build_mingw.bat`, 生成 `build_mingw/liblockin_sdk.a`.

## 快速上手

```cpp
#include <lockin/lockin_sdk.h>
using namespace lockin;

LockinDevice dev;
if (!dev.open()) {                       // 不传端口号 → 自动找 CH340; 也可 dev.open("COM5")
    printf("%s\n", dev.lastError().c_str());
    return;
}

// 振荡器1: 10 kHz, 振荡器2: 20 kHz (手动模式)
dev.setRefMode(RefMode::Manual);
dev.setOscFrequency(1, 10e3);
dev.setOscFrequency(2, 20e3);
dev.setOscTimeConstant(1, 12);           // 低通档位 0..31
dev.setOscFilterOrder(1, 2);             // 1..4 阶

// DAC 输出振荡器1 的正弦, 1 Vpk, 0 V 偏置
dev.setDacSource(1);
dev.setDacWaveform(DacWave::Sine);
dev.setDacAmplitude(1.0);
dev.setDacOffset(0.0);

// 抓一屏 V5 / V6
ScopeConfig cfg;
cfg.decimation = 9;                      // 10 µs/点, 一屏 10.24 ms
cfg.trigger    = ScopeTrigger::V5Rising;
cfg.levelVolts = 0.0;
ScopeData sd;
if (dev.captureScope(sd, cfg)) {
    for (size_t i = 0; i < sd.n; ++i)
        use(sd.timeAt(i), sd.v5[i], sd.v6[i]);   // 秒, 伏
}

// 读锁相结果
dev.startStream();
Frame f;
if (dev.latestFrame(f))
    printf("osc1 R=%.6f Vpk  phase=%.2f deg\n", f.oscRVolts(1), f.oscPhaseDeg(1));
dev.stopStream();
dev.close();
```

所有 `setXxx()` / `sendCommand()` 返回 `bool`: FPGA 回 `Command Success!` 才为 true;
失败时 `lastError()` 给出原因 (参数越界 / 无应答 / FPGA 回 `Command Error!`).
参数越界时 SDK 直接拒绝, 不会发给 FPGA.

## API 说明

### 振荡器 (osc = 1..7)

| 函数 | 说明 | FPGA 命令 |
|---|---|---|
| `setRefMode(Manual/Auto)` | 全局, 7 个振荡器同时生效; 上电为 Manual | `REFMODE` |
| `setOscFrequency(osc, hz)` | Manual 模式基准频率, 0 ~ 32.5 MHz | `FRQ21` / `FRQ12` / `FRQ11` / `FRQ4..7` |
| `setOscHarmonic(osc, N)` | 谐波次数 1..255 | `OHN1..7` |
| `setOscCoefficients(osc, n, m)` | Auto 模式系数 0..255 | `OSC1..7` |
| `setOscInput(osc, src)` | `CH3` / `CH4` / `CH3_minus_CH4` | `OSRC1..7` |
| `setOscTimeConstant(osc, tau)` | 低通档位 0..31 | `TAU21` / `TAU12` / `TAU11` / `TAU4..7` |
| `setOscFilterOrder(osc, k)` | 低通阶数 1..4 | `ORD21` / `ORD12` / `ORD11` / `ORD4..7` |

振荡器 1/2/3 在 FPGA 里沿用历史命名 21/12/11, SDK 已做映射, 调用时只用 1..7.

实际参考频率:

- Manual: `f_ref = setOscFrequency 的值 × N`
- Auto: `f_ref = N × (n·F1 + m·F2)`, F1/F2 为通道1/2 PLL 锁定的频率
  (上电默认 振荡器1 n=2,m=1; 振荡器2 n=1,m=2)

`f_ref` 可从数据帧 `Frame::oscRefHz(osc)` 读回 (FPGA 实际生效值).

时间常数换算: `tauToCutoffHz(tau)` 给出一阶 -3 dB 截止频率, `tauToSeconds(tau)` 给出等效时间常数
(例: tau=12 → fc ≈ 38.9 Hz, TC ≈ 4.1 ms; 每 +1 档时间常数约 ×2).

上电默认: 频率 160k / 170k / 110k / 150k / 180k / 220k / 200k Hz, N=1, 输入 CH3, tau=2, 1 阶.

若板上晶振有偏差, 可用 `setClockCalibration(k)` (k = 实测频率 / 设定频率), 之后
`setOscFrequency` 按 `hz / k` 下发, 使物理输出等于设定值 (同上位机 GUI 的时基标定).

### DAC 输出

| 函数 | 说明 | FPGA 命令 |
|---|---|---|
| `setDacSource(osc)` | 输出哪个振荡器的参考信号, 1..7 | `DMOD:osc-1` |
| `setDacWaveform(Sine/Square)` | 波形 | `DWAV` |
| `setDacAmplitude(vpk)` | 峰值 0 ~ 3.0 V (65535 码 = 3.0 Vpk) | `DAMP` |
| `setDacOffset(v)` | 直流偏置 -3.0 ~ +3.0 V (14 位有符号码) | `DOFS` |

DAC 的频率 = 所选振荡器的参考频率, 没有单独的 DAC 频率设置;
要改 DAC 频率就改该振荡器的 `setOscFrequency` / `setOscHarmonic`.
上电默认: 振荡器1, 正弦, 3.0 Vpk, 0 V.

### 示波器 V5 / V6

```cpp
struct ScopeConfig {
    uint16_t     decimation;  // 每 (decimation+1) 个样点取 1 点, dt = (decimation+1) µs
    ScopeTrigger trigger;     // Free / V5Rising / V5Falling / V6Rising / V6Falling
    double       levelVolts;  // 触发电平, ±10 V
    bool         normalMode;  // false=Auto: 无触发时超时强制抓; true=Normal: 一直等
};
```

- `captureScope(out, cfg, timeoutMs)`: 阻塞抓一屏. 不需要先 `startStream()`.
  内部按上位机 GUI 的做法, 包因误码被 CRC 丢掉时会自动重发抓取命令.
- `armScope(cfg)` + `setScopeCallback(cb)`: 非阻塞, 包到了在回调里给出.
  连续刷新: 在回调里置标志, 由你的线程再调 `armScope()` (回调里不能直接发命令).

`ScopeData`: `n`=1024 点, `pre`=128 (触发点下标), `dt` 采样间隔 (s), `v5`/`v6` 电压 (V),
`v5Raw`/`v6Raw` 原始 int16 码 (1 LSB = 10/32768 V), `timeAt(i)` 为相对触发点的时间,
`forced`=true 表示 Auto 模式下没等到触发、超时强制抓的.

一屏时长 = 1024 × (decimation+1) µs; 串口上传一包 4114 字节约 45 ms.

### 数据流 (锁相结果)

- `startStream()` / `stopStream()`: 开关 FPGA 数据帧上传 (`XYOUT` / `stop`)
- `latestFrame(f)`: 取最近一帧 (轮询用)
- `setFrameCallback(cb)`: 每帧回调 (约 450 次/秒, 在接收线程里调用)

`Frame` 主要成员/方法 (osc = 1..7):

| 成员 | 说明 |
|---|---|
| `oscXVolts(osc)` / `oscYVolts(osc)` | 解调 X / Y, 峰值电压 |
| `oscRVolts(osc)` | 幅值 R (峰值); 有效值 = R/√2 |
| `oscPhaseDeg(osc)` | 相位 atan2(Y, X), 度 |
| `oscRefHz(osc)` | 该振荡器实际参考频率 |
| `pllHz(1/2)`, `ch1Locked()`, `ch2Locked()` | 通道1/2 PLL |
| `oscX[]` / `oscY[]` | 原始码值 (下标 0..6) |
| `sampleCount`, `frameSeq` | FPGA 时间戳 (1 µs) 与帧序号 |

码值 → 电压系数与上位机 GUI 一致 (`voltsPerLsb()`), 重新标定后可用 `setVoltsPerLsb()` 修改.

### 其他

- `LockinDevice::listPorts()`: 枚举串口, CH340 排最前; `findCh340Port()` 返回第一个 CH340
- `sendCommand("XXX:123")`: 发任意原始命令 (不带换行), 用于 SDK 未封装的功能
- `setCommandTimeout(ms)`: 命令应答超时, 默认 500 ms
- 统计: `framesReceived()` / `scopesReceived()` / `crcErrors()`
  (发命令会打断正在发的数据帧, 产生少量 CRC 错误, 属正常)

## 线程与回调

- `open()` 后 SDK 内部有一个接收线程; 所有公有方法线程安全, 命令自动串行化.
- 回调在接收线程里执行: 不要做耗时操作, **不要在回调里调用 `setXxx` / `sendCommand` /
  `captureScope` / `armScope`** (会立即返回 false), 也不要在回调里 `close()`.
  Qt 程序可在回调里 `QMetaObject::invokeMethod(..., Qt::QueuedConnection)` 转到 UI 线程.

## 注意事项

- 串口是独占的: SDK 和上位机 GUI / 串口助手不能同时打开同一个 COM 口.
- `open()` 时会发 `stop` 握手, 无应答则返回 false. 常见原因: FPGA 没加载串口版 bit、
  端口选错、L17/M17 收发接反.
- 每条命令都等 FPGA 应答 (921600 下一般 < 1 ms 往返, 受 USB 串口延迟影响约 1~16 ms).
- 示波器包和数据帧共用一条串口; 数据流开着时抓示波器也没问题.

## 测试 (无板子)

需要一对虚拟串口 (如 ELTIMA / com0com, COM1 ↔ COM2):

```
python tests/fake_fpga.py COM2 30        # 模拟 FPGA, 运行 30 秒
build_mingw\sdk_selftest.exe COM1         # 最后输出 SELFTEST PASSED 即通过
build_mingw\lockin_demo.exe COM1          # 示例程序
```

`fake_fpga.py` 会模拟半帧、垃圾字节、第一个示波器包 CRC 错误, 并把收到的命令写到
`fake_fpga_cmds.txt`, 可核对命令编码.
