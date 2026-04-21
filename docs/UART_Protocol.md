# 数字锁相放大器项目说明

基于 **Xilinx Zynq-7020 (xc7z020clg484-2)** 的**双通道数字锁相放大器 (Dual-Channel Digital Lock-In Amplifier)** 工程，
集成数字 PLL、CIC/IIR 级联滤波、FFT 自动寻峰、UART 参数控制与实时数据回传功能。

---

## 目录

1. [项目简介](#1-项目简介)
2. [硬件平台与工具](#2-硬件平台与工具)
3. [项目文件结构](#3-项目文件结构)
4. [项目迁移与使用说明](#4-项目迁移与使用说明)
5. [Git 分支说明](#5-git-分支说明)
6. [串口通信协议 (UART Protocol)](#6-串口通信协议-uart-protocol)

---

## 1. 项目简介

### 1.1 功能描述

本项目在 FPGA 上实现一个**数字锁相放大器**，用于从噪声中提取微弱信号的幅值与相位信息。

顶层模块：`lock_in_amp`，主要功能链路：

```
ADC 输入 ─► 混频 ─► CIC 抽取滤波 ─► IIR 低通 ─► X/Y 直流分量
              ▲                                    │
              │                                    ▼
         本振 DDS ◄── PLL 控制器 ◄── 相位误差 Y 支路
              ▲
              │
         FFT 寻峰（自动中心频率追踪，可选）
```

双通道独立锁相：通道1 / 通道2 分别对两路 ADC 输入做独立锁定，支持不同信号源。

### 1.2 关键特性

| 特性 | 说明 |
|---|---|
| 主时钟 | 65 MHz（由 MMCM 从 `sys_clk` 生成） |
| ADC 位宽 | 14 bit 双通道 |
| DDS 相位精度 | 48 bit |
| PLL 类型 | 数字二阶 PI 控制器 |
| 滤波结构 | CIC 抽取 → IIR 指数移动平均 |
| 频率追踪 | 65 K 点 FFT 自动寻峰（可选启用） |
| 输出测试信号 | 两路独立 DDS (tx1/tx2) 可配置频率、相位 |
| 和差频输出 | `2F1+F2`、`F1+2F2`、`F1+F2` 三路 |
| 上位机接口 | UART（详见 §6） |
| 实时监控 | ILA 探针抓取多路关键信号 |

---

## 2. 硬件平台与工具

| 项目 | 配置 |
|---|---|
| FPGA | Xilinx Zynq-7020 (`xc7z020clg484-2`) |
| 开发工具 | Vivado **2020.1**（其他版本需 IP 升级，见 §4.3） |
| 仿真工具 | Vivado 内置仿真器 XSim |
| 上位机 | Python / MATLAB 均可，通过 UART 115200 bps 通信 |

---

## 3. 项目文件结构

### 3.1 目录一览

```
git_pll/
├── .gitignore                      # 忽略 Vivado 生成物的规则
├── project_1.xpr                   # Vivado 工程文件
├── update_ips.tcl                  # ★ IP 核一键更新脚本（迁移必用）
│
├── docs/
│   └── UART_Protocol.md            # 本文档（项目说明 + UART 协议）
│
├── project_1.srcs/
│   ├── sources_1/
│   │   ├── new/                    # ★ RTL 源码
│   │   │   ├── lock_in_amp.v       # 顶层模块
│   │   │   ├── pll_controller.v    # 数字 PLL 控制器
│   │   │   ├── fft_peak_tracker.v  # FFT 自动寻峰
│   │   │   ├── iir_lpf_ema.v       # IIR 低通（指数移动平均）
│   │   │   ├── ad_wave_rec.v       # ADC 数据接收/同步
│   │   │   ├── uart_commend.v      # UART 指令解析与数据回传
│   │   │   ├── uart_rec.v          # UART 接收
│   │   │   ├── uart_send.v         # UART 发送
│   │   │   └── uart_xy.v           # XY 数据打包辅助
│   │   │
│   │   └── ip/                     # ★ IP 核配置（只存 .xci）
│   │       ├── clk_wiz_0/          # 时钟向导（产生 65 MHz）
│   │       ├── dds_compiler_1/     # DDS 正余弦发生器
│   │       ├── mult_hunpin/        # 混频乘法器
│   │       ├── cic_compiler_0/     # CIC 抽取滤波器
│   │       ├── xfft_0/             # FFT IP（自动寻峰用）
│   │       └── ila_0/              # 集成逻辑分析仪（调试用）
│   │
│   └── constrs_1/
│       └── new/
│           └── pin.xdc             # 管脚约束
│
└── (Vivado 自动生成的以下目录不入 git：)
    ├── project_1.cache/
    ├── project_1.runs/
    ├── project_1.sim/
    ├── project_1.hw/
    └── .Xil/
```

### 3.2 核心 RTL 源码说明

| 文件 | 作用 |
|---|---|
| `lock_in_amp.v` | **顶层模块**：实例化所有子模块、DDS、和差频、ILA 探针 |
| `pll_controller.v` | 数字二阶 PI 锁相环，输出本振 DDS 的频率控制字 |
| `fft_peak_tracker.v` | 对输入流做 65 K 点 FFT，寻峰得到中心频率估计 |
| `iir_lpf_ema.v` | 指数移动平均 IIR，提取 CIC 后的直流分量（X/Y） |
| `ad_wave_rec.v` | ADC 数据接收与对齐 |
| `uart_commend.v` | UART 指令解析、参数寄存、XYOUT 数据回传状态机 |
| `uart_rec.v` / `uart_send.v` | UART 物理层收/发 |
| `uart_xy.v` | XY 数据帧辅助打包 |

### 3.3 IP 核说明

| IP | 作用 | 典型配置 |
|---|---|---|
| `clk_wiz_0` | 时钟生成 | `sys_clk → 65 MHz` |
| `dds_compiler_1` | DDS 正余弦 | 48 bit PINC，14 bit 输出 |
| `mult_hunpin` | 混频乘法 | 14×14 → 28 bit |
| `cic_compiler_0` | CIC 抽取 | 用于降采样低通 |
| `xfft_0` | 65536 点 FFT | 用于自动频率追踪 |
| `ila_0` | 在线调试 | 多探针实时抓波 |

---

## 4. 项目迁移与使用说明

### 4.1 克隆仓库

```bash
git clone https://gitee.com/ouyang-ming-24/pll-lock-in-amp.git
# 或 GitHub
git clone https://github.com/ouyangming24/-pll-lock-in-amp.git
cd pll-lock-in-amp
```

### 4.2 打开工程

直接双击 `project_1.xpr`，或在 Vivado 里 **File → Open Project...** 选择该文件。

### 4.3 ★ 一键更新并综合所有 IP 核（迁移后必做）

由于仓库只保存 IP 的配置文件（`.xci`），**不保存 IP 的综合产物**（`.dcp` / 仿真文件等），
迁移到新电脑或切换 Vivado 版本后，**顶层综合前必须先生成 IP 产物**。

项目根目录提供了 `update_ips.tcl` 脚本，**一键完成**：
升级 → 重置 → 重新生成产物 → OOC 综合。

#### 方式 A：Vivado GUI 里（推荐）

1. 打开 `project_1.xpr`
2. 底部 **Tcl Console** 输入：

   ```tcl
   cd G:/xiao/git_pll      ;# 改成你的工程路径（正斜杠！）
   source update_ips.tcl
   ```

3. 等日志打印 `✓ 所有 IP 已更新完成` 即可。

#### 方式 B：命令行全自动（无 GUI）

在工程根目录打开 **PowerShell** 或 **cmd**，执行：

```bash
vivado -mode batch -source update_ips.tcl project_1.xpr
```

完成后自动退出。

#### 脚本做了什么

```tcl
upgrade_ip        [get_ips]    # 1. 跨 Vivado 版本时升级 IP
reset_target  all [get_ips]    # 2. 清除旧产物
generate_target all [get_ips]  # 3. 重新生成例化模板、仿真文件等
synth_ip          [get_ips]    # 4. OOC 综合，生成 .dcp（顶层综合必需）
```

### 4.4 综合、实现、生成比特流

IP 更新完成后，按常规 Vivado 流程：

1. **Flow Navigator → Run Synthesis**（顶层综合）
2. **Run Implementation**（布线实现）
3. **Generate Bitstream**（生成 `.bit`）
4. **Open Hardware Manager → Program Device**（下载到 FPGA）

### 4.5 常见问题排查

| 现象 | 可能原因 | 解决方式 |
|---|---|---|
| 综合报 `module 'xxx' not found` | IP 产物没生成 | 跑一遍 `update_ips.tcl` |
| 打开工程后 IP 图标显示 🔒 | Vivado 版本不同导致 IP 锁定 | 跑 `update_ips.tcl` 会自动 `upgrade_ip` |
| `git status` 一大堆黄色文件 | Vivado 自动生成的辅助文件 | 已在 `.gitignore` 忽略，若仍出现可清理后再开 |
| ILA 观察不到波形 | `ila_0` IP 未综合 | `synth_ip [get_ips ila_0]` |
| `git pull` 报 xpr 冲突 | 本地 `.xpr` 被 Vivado 改过 | 先 `git stash` 或 `git checkout -- project_1.xpr` 再 pull |

---

## 5. Git 分支说明

| 分支 | 含义 |
|---|---|
| `master` | 主分支，和最新 feature 分支同步 |
| `main` | GitHub 默认分支（与 master 功能等价） |
| `feature-v3.1` | 当前最新功能分支（双通道 + 串口控制重构） |
| `v3-dual-ad-input` | v3 版：引入双 ADC 通道锁定 |
| `v2-dds-modules` | v2 版：加入和差频 DDS (21/12/11) 和 FRQ3 |

远程仓库：

```
origin  → https://gitee.com/ouyang-ming-24/pll-lock-in-amp.git   (主仓库)
github  → https://github.com/ouyangming24/-pll-lock-in-amp.git   (镜像)
```

---

## 6. 串口通信协议 (UART Protocol)

> 以下内容描述 `lock_in_amp` 顶层模块中 `uart_commend` 子模块实现的串口通信协议，
> 用于 PC 上位机 ↔ FPGA 之间的参数配置、状态查询和数据回传。

### 6.1 物理层参数

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

### 6.2 指令总览

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

#### 6.2.1 指令一览表

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

### 6.3 指令详解

#### 6.3.1 `FREQ:<value>\r\n`
- 位宽：48 bit
- 示例：`FREQ:433038425708\r\n`
- 作用：将 48 位数值写入 `center_freq` 寄存器。
- 备注：当前 `lock_in_amp.v` 改用 FFT 自动寻峰的中心频率（`center_freq_auto_ch1/2`），
  该指令的值未真正作用于控制链路，仅作预留接口。

#### 6.3.2 `KP:<value>\r\n`
- 位宽：16 bit（超出会截断低16位）
- 示例：`KP:500\r\n`
- 作用：PLL 控制器的**比例系数**，通道1、通道2 共用这组 PI 参数。
- 调参建议：初次抓锁阶段可先用 `500~1000`；锁定后若震荡较大，可适当减小。

#### 6.3.3 `KI:<value>\r\n`
- 位宽：16 bit
- 示例：`KI:50\r\n`
- 作用：PLL 控制器的**积分系数**。建议取值 `KP` 的 1/5 ~ 1/10。

#### 6.3.4 `TAUX:<value>\r\n`
- 位宽：5 bit（0 ~ 31）
- 示例：`TAUX:20\r\n`
- 作用：X 支路（同相幅值）IIR 滤波器的指数移动平均**位移量**。
- 效果：值越大滤波越慢、直流分量越平滑，但响应越慢。

#### 6.3.5 `TAUY:<value>\r\n`
- 位宽：5 bit （0 ~ 31）
- 示例：`TAUY:8\r\n`
- 作用：Y 支路（正交相位误差）IIR 滤波器的位移量。
- 调参建议：`TAUY` 一般要比 `TAUX` 小一些（响应更快），
  因为 Y 直接接入 PLL 做反馈，过度滤波会降低环路带宽。

#### 6.3.6 `PHAS:<value>\r\n`
- 位宽：48 bit
- 示例：`PHAS:0\r\n`
- 作用：测试 DDS `tx1` 的**初始相位字**（POFF）。
- 相位换算：`PHAS 数值 / 2^48 × 360°`
  例如 `PHAS:70368744177664\r\n` = `2^46`，对应约 `90°` 相位偏移。

#### 6.3.7 `FRQ2:<value>\r\n`
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

#### 6.3.8 `FRQ3:<value>\r\n`
- 位宽：48 bit
- 示例：`FRQ3:2165192128540\r\n`
- 作用：测试 DDS `tx2` 的频率字（与 `FRQ2` 独立）。
- 换算方法同 `FRQ2`。

#### 6.3.9 `XYOUT`
- 格式：`XYOUT`（**无冒号、无 `\r\n` 结尾**，最后一个字节是 `T`）
- 作用：启动通道1 的 X/Y 直流量连续回传（见 §6.4）。
- 发送成功后 FPGA 会回 `Command Success!\r\n`，随后开始持续输出数据帧。

#### 6.3.10 `stop`
- 格式：`stop`（**全小写**，末字节为 `p`）
- 作用：停止连续数据回传，FPGA 回到空闲状态并返回 `Command Success!\r\n`。
- 注意：该指令与上面的指令不同，**指令字符必须完全小写**。

### 6.4 响应与数据回传格式

#### 6.4.1 指令响应

FPGA 收到任何指令后都会回一条响应字符串：

| 情况 | 响应字符串 | 长度 |
|---|---|---|
| 指令识别成功（无论是否有值） | `Command Success!\r\n` | 18 字节 |
| 指令无法识别 / 格式错误 / 超长 | `Command Error!\r\n` | 16 字节 |

上位机可根据这条响应判断是否需要重试。

#### 6.4.2 XYOUT 数据帧格式

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

### 6.5 典型上位机流程

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

### 6.6 容错与注意事项

1. **指令大小写敏感**：除 `stop` 是全小写，其他指令（`KP`/`KI`/`FREQ`/`TAUX`/`TAUY`/`PHAS`/`FRQ2`/`FRQ3`/`XYOUT`）都必须**全大写**。
2. **数值仅支持十进制**：`value_buffer` 解析逻辑是 `value * 10 + (ascii - '0')`，
   暂不支持 `0x` 十六进制、负号、小数点。
3. **指令超长**：若指令字符数累计 ≥ 9 还未匹配任何已知指令，会返回 `Command Error!\r\n` 并丢弃。
4. **换行容错**：只要遇到 `\r` 或 `\n` 就认为本次输入结束。可以单独用 `\n`，也可以 `\r\n`。
5. **`XYOUT` 期间收到任何字节**：会立即打断当前数据帧，进入指令解析流程（可用于紧急中断）。
6. **FPGA 复位**：`sys_rst_n` 拉低后所有寄存器恢复默认值（见 §6.2.1 默认值列）。

### 6.7 源码映射

以下列出协议各条款对应的源码位置，便于维护与追踪：

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

*本文档与源码版本一致性请以对应 `.v` 文件最新内容为准，若修改 RTL/指令/字段务必同步更新此文档。*
