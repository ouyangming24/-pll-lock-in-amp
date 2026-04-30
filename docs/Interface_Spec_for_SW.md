# 上位机接口规约（给软件工程师）

> 本文档定义 FPGA 与 PC 端软件之间的通信接口契约。
> **接口已冻结**，软件按本文档实现，无需了解 FPGA 内部细节。

---

## 1. 物理层

| 项 | 内容 |
|---|---|
| 设备 | FTDI **FT245BL** USB-FIFO |
| USB | USB 2.0 Full Speed (12 Mbps) |
| 工作模式 | 8 位并行 FIFO（PC 端透明） |
| 驱动 | FTDI 官方 VCP 或 D2XX，二选一 |
| 设备识别 | VID=0x0403, PID=0x6001 (FT232/245 默认) |

PC 端表现：
- **VCP 模式**：设备管理器显示一个 COM 口，用 `pyserial` / `Putty` 即可
- **D2XX 模式**：设备管理器显示 USB 设备，需要 `pyftdi` / `ftd2xx` 库

> 推荐开发期用 VCP，速度足够，调试方便；生产上有性能要求再切 D2XX。

---

## 2. 链路层

| 项 | 数值 |
|---|---|
| 数据位 | 8 |
| 字节序 | **大端**（高字节先发） |
| 流控 | FT245 自带硬件握手（PC 不可见） |
| 波特率 | VCP 模式下任意值，被驱动忽略；建议设 `3 000 000` |
| 端到端往返延迟 | 典型 < 50 ms |

---

## 3. 应用层协议

通信是**半双工式**：
- PC 主动发命令 → FPGA 回应答
- PC 发 `XYOUT` 后，FPGA 周期性回 48 字节数据帧
- PC 发 `stop` 关闭数据流

### 3.1 PC → FPGA：ASCII 命令

**格式**：
```
<命令>[:参数]\r\n
```

- 大小写敏感
- 参数为 **十进制无符号整数**字符串
- 必须以 `\r\n`（或 `\n`）结尾

**完整命令表**：

| 命令 | 参数范围 | 说明 |
|---|---|---|
| `KP:<num>` | 0..65535 | PLL 比例系数 |
| `KI:<num>` | 0..65535 | PLL 积分系数 |
| `TAUX:<num>` | 0..31 | X 路 IIR 平滑系数（位移量，越大越平滑/越慢） |
| `TAUY:<num>` | 0..31 | Y 路 IIR 平滑系数 |
| `FREQ:<num>` | 0..2⁴⁸-1 | 中心频率字（保留，当前未使用） |
| `PHAS:<num>` | 0..2⁴⁸-1 | tx1 相位偏移字 |
| `FRQ2:<num>` | 0..2⁴⁸-1 | tx1 频率字 |
| `FRQ3:<num>` | 0..2⁴⁸-1 | tx2 频率字 |
| `XYOUT` | （无参数） | 启动 48 字节数据帧周期性回传 |
| `stop` | （无参数） | 停止数据帧回传 |

**频率字换算公式**（48 位 DDS）：
```
frequency_word = round(f_target_Hz × 2^48 / f_clk)
其中 f_clk = 65 MHz（系统 DDS 时钟）

例: f_target = 1 kHz → frequency_word = round(1000 × 2^48 / 65e6) ≈ 4_330_384_257
```

### 3.2 FPGA → PC：命令应答（每条命令必回）

固定 18 字节，用于流控和确认：

| 应答 | 字节内容 | 含义 |
|---|---|---|
| 成功 | `Command Success!\r\n` | 命令解析正确，参数已生效 |
| 失败 | `Command Error!\r\n`（16 字节） | 命令格式错误或未知命令 |

> ⚠️ 软件**必须等收到应答**再发下一条命令，否则可能丢命令。

### 3.3 FPGA → PC：80 字节数据帧（XYOUT 后周期回传）

> **协议版本 v1.1**（v1.0 是 48 字节帧，已废弃）

**完整帧布局（大端）**：

| 偏移 | 长度 | 字段 | 类型 | 含义 |
|:---:|:---:|---|---|---|
| 0  | 4 | **同步头** | `0xA5 5A A5 5A` | 固定魔数，用于对齐 |
| 4  | 4 | `ch1_x`     | int32 | 通道1 @ F1 的 X 分量 |
| 8  | 4 | `ch1_y`     | int32 | 通道1 @ F1 的 Y 分量 |
| 12 | 4 | `ch2_x`     | int32 | 通道2 @ F2 的 X 分量 |
| 16 | 4 | `ch2_y`     | int32 | 通道2 @ F2 的 Y 分量 |
| 20 | 4 | `ch3_x_21`  | int32 | 通道3 @ (2F1+F2) X |
| 24 | 4 | `ch3_y_21`  | int32 | 通道3 @ (2F1+F2) Y |
| 28 | 4 | `ch3_x_12`  | int32 | 通道3 @ (F1+2F2) X |
| 32 | 4 | `ch3_y_12`  | int32 | 通道3 @ (F1+2F2) Y |
| 36 | 4 | `ch3_x_11`  | int32 | 通道3 @ (F1+F2)  X |
| 40 | 4 | `ch3_y_11`  | int32 | 通道3 @ (F1+F2)  Y |
| 44 | 4 | `ch3_dc`    | int32 | 通道3 直流分量 |
| **48** | **4** | **`adc_ch1`** | **int32** | **★ 通道1 原始 ADC 瞬时采样 (14bit 符号扩展)** |
| **52** | **4** | **`adc_ch2`** | **int32** | **★ 通道2 原始 ADC 瞬时采样** |
| **56** | **4** | **`adc_ch3`** | **int32** | **★ 通道3 原始 ADC 瞬时采样** |
| **60** | **8** | **`pll_freq_ch1`** | **uint64** | **★ 通道1 锁定的 DDS 频率字 (低 48bit 有效, 高 16bit 为 0)** |
| **68** | **8** | **`pll_freq_ch2`** | **uint64** | **★ 通道2 锁定的 DDS 频率字** |
| **76** | **4** | **`lock_flags`** | **int32** | **★ bit 0 = ch1 锁定, bit 1 = ch2 锁定, 其余位保留** |

**重要约定**：
1. 所有 28 位 / 14 位有符号数据均**符号扩展到 32 位**
2. `pll_freq_ch1/ch2` 是 48 位频率字，高位补 0 后形成 64 位无符号
   - 物理频率换算：`f_Hz = word × F_CLK / 2^48`，其中 `F_CLK = 65 MHz`
3. `lock_flags` 是位掩码：`is_locked_ch1 = (lock_flags >> 0) & 1`
4. **同步头不是 4 字节连续 ASCII**，是 4 个字节 `A5 5A A5 5A`
5. 帧之间**没有分隔符**，靠同步头自对齐
6. **典型帧率**：50–100 Hz（取决于 `TAUX/TAUY`）
7. **绝不会拆包**：80 字节是原子的，不存在跨帧的不完整字节序列

**Python `struct` 解析示例**：

```python
import struct
SYNC = b'\xA5\x5A\xA5\x5A'
FRAME_LEN = 80
fmt = '>11i' + '3i' + 'QQ' + 'i'   # 11 锁相 + 3 ADC + 2 频率 + 1 锁定标志
fields = struct.unpack(fmt, frame[4:])  # 跳过 4 字节同步头
ch1_x, ch1_y, ch2_x, ch2_y, \
ch3_x_21, ch3_y_21, ch3_x_12, ch3_y_12, ch3_x_11, ch3_y_11, ch3_dc, \
adc_ch1, adc_ch2, adc_ch3, \
pll_freq_ch1_word, pll_freq_ch2_word, \
lock_flags = fields

f1_hz = pll_freq_ch1_word * 65e6 / (1 << 48)
f2_hz = pll_freq_ch2_word * 65e6 / (1 << 48)
ch1_locked = bool(lock_flags & 1)
ch2_locked = bool(lock_flags & 2)
```

---

## 4. PC 端推荐解析伪代码

```python
SYNC = b'\xA5\x5A\xA5\x5A'
buf = b''
while running:
    buf += read_from_device(64)        # 读任意长度数据
    while True:
        idx = buf.find(SYNC)
        if idx < 0 or len(buf) - idx < 48:
            break                       # 未对齐或不够一帧
        frame = buf[idx : idx + 48]
        buf   = buf[idx + 48 :]         # 消费已解析的字节
        ch1_x, ch1_y, ch2_x, ch2_y, \
        ch3_x_21, ch3_y_21, \
        ch3_x_12, ch3_y_12, \
        ch3_x_11, ch3_y_11, ch3_dc = struct.unpack('>11i', frame[4:])
        on_new_frame(...)
```

---

## 5. 常见问答

**Q1：可以同时支持 VCP 和 D2XX 吗？**
A：**不能同时**，是 FT_PROG 工具里二选一的硬件配置。换模式要重新配置 EEPROM。

**Q2：发了 `XYOUT` 后能再发其他命令吗？**
A：**可以**。`usb_commend.v` 的状态机在数据流中也监听 `rec_done`，收到字节立即跳出数据流去处理新命令。

**Q3：丢包怎么处理？**
A：链路层有 USB CRC，丢包概率极低。一旦应用层发现帧解析失败（同步头匹配不上），靠重新搜索 `0xA5 5A A5 5A` 自然恢复。

**Q4：为什么是大端？**
A：FPGA 端 `usb_commend.v` 从最高位开始送字节（`xy_data_reg[383-byte_cnt*8 -: 8]`），自然就是大端。Python `struct` 用 `'>'` 前缀解析。

**Q5：如何抓原始数据用来离线测试？**
A：用串口助手或下面命令：
```bash
# Windows PowerShell
mode COM5 BAUD=115200
type COM5 > capture.bin

# Python 一行
python -c "import serial,sys; \
  ser=serial.Serial('COM5'); \
  open('capture.bin','wb').write(ser.read(4800))"
```

---

## 6. 联调流程

```
1. 硬件端 (FPGA 工程师) 烧录比特流, 上电
2. 软件端 (你, PC 工程师) 装好 FTDI 驱动
3. 用串口助手发: KP:500\r\n
   ✅ 收到 'Command Success!' → 命令链路通
4. 发 XYOUT\r\n, 用 hex 查看工具看是否周期性出现 A5 5A A5 5A 头
   ✅ 看到帧头 → 数据链路通
5. 实现 Python/C++ 上位机, 解析后绘图或存盘
```

参考实现见仓库 `tools/host_vcp.py` 和 `tools/host_d2xx.py`。

---

## 7. 联系人 / 变更管理

| 角色 | 负责 |
|---|---|
| FPGA 端 | < 你的名字 > |
| PC 软件 | < 软件工程师名字 > |

**协议变更原则**：
- 任何字段增删 → **协议版本号**升级，需双方书面同意
- 同步头如需修改，提前知会软件端预留时间适配
- 命令名只能增加新命令，不能修改现有命令含义
- 数据帧字段只能在尾部追加，不能改既有字段位置

_文档版本：v1.0 · 2026-04-21_
