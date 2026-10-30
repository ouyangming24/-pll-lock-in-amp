# Lock-In Osc1 Stream SDK (`lockin_sdk_osc1`)

面向新上位机的精简串口 SDK。与经典 `lockin_sdk_cpp` / GUI **并存**：

| | GUI / `lockin_sdk_cpp` | 本 SDK |
|---|---|---|
| 流命令 | `XYOUT` | `SDKOUT` |
| 帧长 | 178 B（全通道） | **28 B**（仅振荡器1 + V3/V4/V5） |
| 示波器 | `SCAP` 攒 1024 点整包 | **无**（每帧已带 V3/V4/V5 瞬时样点） |
| 控制 | 振荡器 1..7 + DAC + 示波器 | **振荡器1 + DAC**（控制命令兼容） |

串口: 板载 CH340, **默认 115200** 8N1（`BAUD:` 可调）。仅依赖 Win32 + C++17。

## 目录

```
lockin_sdk_osc1/
  include/lockin_osc1/lockin_sdk.h
  src/lockin_sdk.cpp
  src/serial_port.h, serial_port_win.cpp
  examples/demo.cpp
  tests/fake_fpga.py, sdk_selftest.cpp
  CMakeLists.txt, build_mingw.bat
```

## SDKOUT 帧 (28 字节, 大端)

| 偏移 | 字段 | 类型 |
|------|------|------|
| 0 | sync `A5 5A C3 01` | 4 B |
| 4 | osc1_x / osc1_y | int32 ×2 |
| 12 | V3 / V4 / V5 | int16 ×3 |
| 18 | sample_cnt | uint32 |
| 22 | frame_seq | uint32 |
| 26 | CRC16-CCITT-FALSE (覆盖 0..25) | uint16 |

FPGA 按 ADC `conv_done` 刷新快照；串口实际约 **2 k 帧/s**（带宽受限）。详见 `docs/handbook/02_通信协议_串口版.md`。

## 快速上手

```cpp
#include <lockin_osc1/lockin_sdk.h>
using namespace lockin_osc1;

LockinDevice dev;
if (!dev.open()) return;                 // 自动找 CH340, 或 open("COM5")

dev.setRefMode(RefMode::Manual);
dev.setOsc1Frequency(10e3);
dev.setOsc1TimeConstant(12);
dev.setOsc1FilterOrder(2);

dev.setDacSourceOsc1();
dev.setDacWaveform(DacWave::Sine);
dev.setDacAmplitude(1.0);

dev.setFrameCallback([](const Frame& f) {
    // f.osc1RVolts(), f.v3Volts(), f.v4Volts(), f.v5Volts()
});
dev.startStream();   // SDKOUT
// ...
dev.stopStream();
dev.close();
```

## 编译

- **MinGW**: `build_mingw.bat` → `build_mingw/liblockin_sdk_osc1.a` + demo/selftest
- **CMake**: `cmake -B build && cmake --build build --config Release`
- 源码直接加入工程: include 加 `include/`, 编译 `src/*.cpp`, 链接 `setupapi`

## 无板自测

```bat
python tests\fake_fpga.py COM2
build_mingw\sdk_osc1_selftest.exe COM1
```
