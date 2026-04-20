# 串口通信协议说明 (UART Protocol)

本文档描述 `lock_in_amp` 顶层模块中 `uart_commend` 子模块实现的串口通信协议，
用于 PC 上位机 ↔ FPGA 之间的参数配置、状态查询和数据回传。

---

## 1. 物理层参数

| 项目 | 配置 |
|---|---|
| 接口 | UART |
| 波特率 | 由 `uart_rec` / `uart_send` 模块决定（默认 115200 bps，请以实际配置为准） |
| 数据位 | 8 |
| 校验位 | 无 |
| 停止位 | 1 |
| 流控 | 无 |
| 编码 | ASCII |
| 时钟域 | `sys_clk`（FPGA 系统时钟） |
| 行结束符 | `\r\n`（CR+LF）或 `\n` 均可 |

---

## 2. 指令总览

所有输入的参数设置指令均遵循统一格式：

```
<CMD>:<decimal_value>\r\n
```

- `<CMD>`：指令名称（全大写，长度固定，详见下表）
- `:`：指令和参数的分隔符
- `<decimal_value>`：**十进制无符号整数**（最多按 48-bit 处理）
- `\r\n`：终止符（也接受单独的 `\n`）

另外有两条**控制型**指令，不带数值和冒号：
- `XYOUT`（启动连续数据回传）
- `stop`（停止数据回传，**全小写**！）

### 2.1 指令一览表

| 指令 | 长度 | 参数位宽 | 用途 | 默认值 (复位后) |
|---|---|---|---|---|
| `FREQ` | 4 字符 | 48 bit | 设置中心频率寄存器（FPGA 里目前未实际使用，保留） | `433038425708` |
| `KP` | 2 字符 | 16 bit | PLL 比例系数 | `500` |
| `KI` | 2 字符 | 16 bit | PLL 积分系数 | `50` |
| `TAUX` | 4 字符 | 5 bit | 通道1 X 方向 IIR 时间常数（越大越慢）| `20` |
| `TAUY` | 4 字符 | 5 bit | 通道1 Y 方向 IIR 时间常数 | `8` |
| `PHAS` | 4 字符 | 48 bit | 测试 DDS `tx1` 相位偏移 | `0` |
| `FRQ2` | 4 字符 | 48 bit | 测试 DDS `tx1` 频率控制字 | `433471464133` |
| `FRQ3` | 4 字符 | 48 bit | 测试 DDS `tx2` 频率控制字 | `0` |
| `XYOUT` | 5 字符 | —  | 启动 X/Y 直流量连续回传 | 关闭 |
| `stop` | 4 字符 | — | 停止 X/Y 连续回传 | — |

---

## 3. 指令详解

### 3.1 `FREQ:<value>\r\n`
- 位宽：48 bit
- 示例：`FREQ:433038425708\r\n`
- 作用：将 48 位数值写入 `center_freq` 寄存器。
- 备注：当前 `lock_in_amp.v` 改用 FFT 自动寻峰的中心频率（`center_freq_auto_ch1/2`），
  该指令的值未真正作用于控制链路，仅作预留接口。

### 3.2 `KP:<value>\r\n`
- 位宽：16 bit（超出会截断低16位）
- 示例：`KP:500\r\n`
- 作用：PLL 控制器的**比例系数**，通道1、通道2 共用这组 PI 参数。
- 调参建议：初次抓锁阶段可先用 `500~1000`；锁定后若震荡较大，可适当减小。

### 3.3 `KI:<value>\r\n`
- 位宽：16 bit
- 示例：`KI:50\r\n`
- 作用：PLL 控制器的**积分系数**。建议取值 `KP` 的 1/5 ~ 1/10。

### 3.4 `TAUX:<value>\r\n`
- 位宽：5 bit（0 ~ 31）
- 示例：`TAUX:20\r\n`
- 作用：X 支路（同相幅值）IIR 滤波器的指数移动平均**位移量**。
- 效果：值越大滤波越慢、直流分量越平滑，但响应越慢。

### 3.5 `TAUY:<value>\r\n`
- 位宽：5 bit（0 ~ 31）
- 示例：`TAUY:8\r\n`
- 作用：Y 支路（正交相位误差）IIR 滤波器的位移量。
- 调参建议：`TAUY` 一般要比 `TAUX` 小一些（响应更快），
  因为 Y 直接接入 PLL 做反馈，过度滤波会降低环路带宽。

### 3.6 `PHAS:<value>\r\n`
- 位宽：48 bit
- 示例：`PHAS:0\r\n`
- 作用：测试 DDS `tx1` 的**初始相位字**（POFF）。
- 相位换算：`PHAS 数值 / 2^48 × 360°`
  例如 `PHAS:70368744177664\r\n` = `2^46`，对应约 `90°` 相位偏移。

### 3.7 `FRQ2:<value>\r\n`
- 位宽：48 bit
- 示例：`FRQ2:433038425708\r\n`
- 作用：测试 DDS `tx1` 的**频率字**（PINC），用来输出一个可 DAC 外送的测试正弦波。
- 频率换算（65 MHz DDS 时钟）：
  `f_out = PINC × 65,000,000 / 2^48`

  换算示例：
  | PINC | f_out (约) |
  |---|---|
  | `433038425708` | 100 kHz |
  | `4330384257` | 1 kHz |
  | `4330384257080` | 1 MHz |

### 3.8 `FRQ3:<value>\r\n`
- 位宽：48 bit
- 示例：`FRQ3:2165192128540\r\n`
- 作用：测试 DDS `tx2` 的频率字（与 `FRQ2` 独立）。
- 换算方法同 `FRQ2`。

### 3.9 `XYOUT`
- 格式：`XYOUT`（**无冒号、无 `\r\n` 结尾**，最后一个字节是 `T`）
- 作用：启动通道1 的 X/Y 直流量连续回传（见 §4）。
- 发送成功后 FPGA 会回 `Command Success!\r\n`，随后开始持续输出数据帧。

### 3.10 `stop`
- 格式：`stop`（**全小写**，末字节为 `p`）
- 作用：停止连续数据回传，FPGA 回到空闲状态并返回 `Command Success!\r\n`。
- 注意：该指令与上面的指令不同，**指令字符必须完全小写**。

---

## 4. 响应与数据回传格式

### 4.1 指令响应

FPGA 收到任何指令后都会回一条响应字符串：

| 情况 | 响应字符串 | 长度 |
|---|---|---|
| 指令识别成功（无论是否有值） | `Command Success!\r\n` | 18 字节 |
| 指令无法识别 / 格式错误 / 超长 | `Command Error!\r\n` | 16 字节 |

上位机可根据这条响应判断是否需要重试。

### 4.2 XYOUT 数据帧格式

开启 `XYOUT` 后，每当通道1 的 IIR 输出更新一次新的直流值（`dc_valid_x_ch1` 上升沿），
FPGA 就会把最近一次 `dc_x_ch1` 和 `dc_y_ch1` 组包发给上位机。

**数据包结构（共 16 字节，高字节在前 / Big-Endian）：**

```
┌────────────┬────────────┬────────────┬────────────┐
│  Byte[15]  │  Byte[14]  │  ...       │  Byte[0]   │   
│  MSB                                       LSB    │
└────────────┴────────────┴────────────┴────────────┘
   │← 高 64 位 = {36'd0, dc_x_ch1[27:0]}  →│
                                 │← 低 64 位 = {36'd0, dc_y_ch1[27:0]} →│
```

- 每个 `dc` 量为 **28-bit 有符号整数**，在 64-bit 容器中**低 28 位有效**，
  高 36 位补 0 （如果 dc 为负值，也只保留低 28 位的补码形式）。
- 总共 128 bit = 16 字节，从**字节 15（最高字节）先发送**，到**字节 0（最低字节）最后发送**。
- 每一帧发送完成后会有约 `5,000,000` 个 `sys_clk` 周期的**延时间隔**，避免刷屏过快。
  （若 `sys_clk` = 50 MHz，间隔约 **100 ms**；50 M × 0.1 s = 5 M）

**解析示例（Python 伪代码）：**
```python
def parse_xyout_frame(raw_bytes):
    assert len(raw_bytes) == 16
    high64 = int.from_bytes(raw_bytes[0:8],  'big')
    low64  = int.from_bytes(raw_bytes[8:16], 'big')
    # 取低 28 bit 做有符号扩展
    def to_signed_28(v):
        v &= (1 << 28) - 1
        return v - (1 << 28) if v & (1 << 27) else v
    dc_x = to_signed_28(high64 & ((1 << 28) - 1))
    dc_y = to_signed_28(low64  & ((1 << 28) - 1))
    return dc_x, dc_y
```

---

## 5. 典型上位机流程

以下为 PC 端典型的工作流程（伪代码）：

```python
import serial, time

ser = serial.Serial('COMx', 115200, timeout=1)

def send_cmd(cmd: str):
    ser.write((cmd + '\r\n').encode('ascii'))
    return ser.read(18)  # 最多读 18 字节响应

# --- 1. 配置参数 ---
send_cmd('KP:800')
send_cmd('KI:80')
send_cmd('TAUX:20')
send_cmd('TAUY:8')
send_cmd('FRQ2:433038425708')   # tx1 = 100 kHz
send_cmd('FRQ3:0')              # tx2 关闭
send_cmd('PHAS:0')

# --- 2. 启动数据流 ---
ser.write(b'XYOUT')             # 注意 XYOUT 不带 \r\n
_ = ser.read(18)                # 消掉 "Command Success!\r\n"

# --- 3. 实时解析 ---
try:
    while True:
        frame = ser.read(16)
        if len(frame) == 16:
            dc_x, dc_y = parse_xyout_frame(frame)
            print(f"X = {dc_x:+d}, Y = {dc_y:+d}")
except KeyboardInterrupt:
    pass

# --- 4. 停止数据流 ---
ser.write(b'stop\r\n')
```

---

## 6. 容错与注意事项

1. **指令大小写敏感**：除 `stop` 是全小写，其他指令（`KP`/`KI`/`FREQ`/`TAUX`/`TAUY`/`PHAS`/`FRQ2`/`FRQ3`/`XYOUT`）都必须**全大写**。
2. **数值仅支持十进制**：`value_buffer` 解析逻辑是 `value * 10 + (ascii - '0')`，
   暂不支持 `0x` 十六进制、负号、小数点。
3. **指令超长**：若指令字符数累计 ≥ 9 还未匹配任何已知指令，会返回 `Command Error!\r\n` 并丢弃。
4. **换行容错**：只要遇到 `\r` 或 `\n` 就认为本次输入结束。可以单独用 `\n`，也可以 `\r\n`。
5. **`XYOUT` 期间收到任何字节**：会立即打断当前数据帧，进入指令解析流程（可用于紧急中断）。
6. **FPGA 复位**：`sys_rst_n` 拉低后所有寄存器恢复默认值（见 §2.1 默认值列）。

---

## 7. 源码映射

以下列出文档各条款对应的源码位置，便于维护与追踪：

| 协议元素 | 源码行号 | 文件 |
|---|---|---|
| 指令枚举 `CMD_FREQ` ... `CMD_FRQ3` | `uart_commend.v : 30~39` | `uart_commend.v` |
| 复位默认值 | `uart_commend.v : 111~117` | `uart_commend.v` |
| 指令解析状态机 | `uart_commend.v : 142~231` | `uart_commend.v` |
| 数值解析 / 赋值 | `uart_commend.v : 233~268` | `uart_commend.v` |
| `Success` 响应字符串 | `uart_commend.v : 63~68` | `uart_commend.v` |
| `Error` 响应字符串 | `uart_commend.v : 70~75` | `uart_commend.v` |
| XYOUT 数据打包 | `lock_in_amp.v` 中 `x_y_fir_packed` | `lock_in_amp.v` |
| XYOUT 字节输出 | `uart_commend.v : 316` (`xy_data_reg[127-byte_cnt*8 -: 8]`) | `uart_commend.v` |
| 帧间延时常量 `DELAY_1S` | `uart_commend.v : 54` | `uart_commend.v` |

---

*本文档与源码版本一致性请以 `uart_commend.v` 最新内容为准，若修改指令/字段务必同步更新此文档。*
