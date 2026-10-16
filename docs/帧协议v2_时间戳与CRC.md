# 帧协议 v2：采样时间戳 + 帧序号 + CRC16

> 日期：2026-10-15
> 适用：`lock_in_amp.v` / `usb_commend.v` / `ft245_tx.v` 与 `lockin_gui/device.py`、`lockin_gui/main_window.py`
> **硬件比特流与 GUI 必须同时更新**，新旧版本互不兼容（见第 6 节）。

---

## 1. 为什么要改

对全速录制的数据（`全速2.csv`，12842 帧，约 2400 帧/s）分析后发现了三个问题：

| 现象 | 根因 | 影响 |
|---|---|---|
| 曲线出现"有规律的小幅正弦波动"，频率随抽样比例变化（10% 时约 20 Hz） | GUI 用 PC 收到帧的时刻 `time.time()` 作时间戳；FT245 VCP 驱动约每 8~10 ms 成批交付约 22 帧，同批帧时间戳几乎相同 | 时间误差是约 100 Hz 的锯齿，乘以信号变化率即成为数值上的周期误差；抽样后折叠成 ~20 Hz。全速数据频谱在 102.8 Hz 及倍频有假峰，改用均匀时间轴后假峰消失 |
| 个别字段偶发几千 mV 的尖峰（约 1.8% 的帧） | 帧结构正常，但个别字节被替换（如 `FFFB0255` → `FF020241`，相邻两字节变成相同值） | 坏值直接进入曲线和 CSV；低位字节被改时与噪声无法区分 |
| 流模式下发命令时出现乱帧，界面偶发显示 `CCommand ...` | ① FPGA 发帧中途被命令打断，插入 18 字节 ASCII 应答，GUI 只校验同步头，把"半帧 + ASCII + 下一帧开头"当成一帧解析；② `ft245_tx` 按电平触发，每个字节都被重复发送一次（见 3.4 节） | 乱帧进入 CSV，下一帧也丢失 |

协议里原先没有校验、没有帧序号、没有采样时刻，上面这些问题既无法在线识别，也无法事后追查。

---

## 2. 改动总览

| 文件 | 改动 |
|---|---|
| `project_1.srcs/sources_1/new/lock_in_amp.v` | 新增 32 位 `sample_cnt`（对 `dc_valid_x_ch1` 的 1 MHz 节拍计数），打包到快照末尾；`x_y_fir_packed` 由 1344 位扩为 1376 位 |
| `project_1.srcs/sources_1/new/usb_commend.v` | 追加 32 位 `frame_seq` 和 CRC16，帧长由 168 字节改为 178 字节；进入发送时立即冻结快照，修复偶发重复帧 |
| `project_1.srcs/sources_1/new/ft245_tx.v` | 改为在 `send_en` 上升沿启动发送，修复每个字节被重复发送的问题 |
| `lockin_gui/device.py` | 解析 v2 帧并校验 CRC，校验失败只跳过 1 字节后重新对齐；新增 `FrameTracker`，用 `sample_cnt` 生成时间轴、用 `frame_seq` 统计丢帧；删除临时方案 `FrameClock` 和 `SpikeGuard` |
| `lockin_gui/main_window.py` | CSV 新增 `fpga_time_s`、`frame_seq` 两列及协议元数据；状态栏显示"坏帧"和"丢帧" |

---

## 3. FPGA 改动细节

### 3.1 采样时间戳 `sample_cnt`（`lock_in_amp.v`）

```verilog
reg [31:0] sample_cnt;
always @(posedge clk_65M or negedge rst_n_65m)
    if (!rst_n_65m)          sample_cnt <= 32'd0;
    else if (dc_valid_x_ch1) sample_cnt <= sample_cnt + 32'd1;
```

- 计数节拍是帧触发信号 `dc_valid_x_ch1`，频率为 65 MHz / 65（CIC 抽取比）= 1 MHz，即 1 LSB 对应 1 µs。
- `usb_commend` 在 `dc_valid_x_ch1` 上升沿把整个 `x_y_fir_packed`（含 `sample_cnt`）锁存为快照，所以时间戳和测量值来自同一拍，是原子的。
- 32 位约 71.6 分钟回绕一次，由上位机负责展开。

### 3.2 帧序号 `frame_seq`（`usb_commend.v`）

- 每锁存一帧快照加 1：`xy_data_reg <= {x_y_fir, frame_seq}`。
- 上位机看到序号跳号即为丢帧（包括 CRC 校验失败被丢弃的帧）。
- FPGA 按 USB 能接收的速度去取最新快照，`sample_cnt` 本来就不连续；只有 `frame_seq` 跳号才表示"发出了但没被收到"。

### 3.3 CRC16（`usb_commend.v`）

- 算法：CRC-16/CCITT-FALSE（多项式 0x1021，初值 0xFFFF，不反射，输出不异或），标准校验值 `"123456789"` → `0x29B1`。
- 范围：覆盖第 0 到 175 字节（含同步头），CRC 本身放在第 176、177 字节，高字节在前。
- 实现：边发边算。每个数据字节在 `WAIT_XYDATA` 收到 `tx_done` 时，用已寄存的 `send_data` 更新 `tx_crc`。逻辑路径只有一个寄存器加 8 级异或，不经过 176 选 1 的字节选择器，对时序影响很小。
- 帧开始时（`IDLE → SEND_XYDATA`）`tx_crc` 复位为 0xFFFF。
- 与 Python 的 `binascii.crc_hqx(data, 0xFFFF)` 定义一致。Python 侧已用标准校验值验证；Verilog 函数按同一定义逐位编写（MSB 先入），**尚未仿真**，以上板时状态栏"坏帧"计数为准。

### 3.4 `ft245_tx` 握手修复：每个字节被发两次

原来的握手时序：

1. `usb_commend` 拉高 `send_en`，并一直保持到看见 `tx_done`；
2. `ft245_tx` 在 `ST_DONE` 拍发出 `tx_done`，下一拍回到 `IDLE`；
3. 在这一拍，`ft245_tx` 已经回到 `IDLE`，而 `send_en` 还没来得及拉低（`usb_commend` 下一拍才拉低）。按电平触发，`ft245_tx` 会立刻把同一个字节再发一次。

结果是每帧（和每条应答）的第一个字节多发一遍，后面的字节与 `tx_done` 计数错位一拍：

- 数据帧变成 `A5 A5 5A A5 5A ...`，共 169 字节。解析器从第二个 `A5` 开始对齐，所以之前"碰巧能用"。
- 应答变成 `CCommand Success!\r\n`。`docs/BD_OOC_双IOBUF_USB命令Error.md` 中记录的"界面偶发显示 `CCommand Error!`"就是这个原因，并不是粘包。

修复方法：`ft245_tx` 只在 `send_en` 的上升沿（`send_en & ~send_en_d`）启动一次发送。

> 这次修复是否也解决了约 1.8% 的字节替换，需要上板验证（见第 7 节）。即使没有解决，CRC 也会把这些帧全部拦下。

### 3.5 重复帧修复（`usb_commend.v`）

原来 `IDLE → SEND_XYDATA` 的第一拍里 `data_sending` 仍为 0。如果这一拍恰好来了 `dc_valid` 上升沿，快照会被覆盖，`new_data_ready` 又被置 1，可能连发两帧几乎相同的数据。现在在进入 `SEND_XYDATA` 的同一拍就把 `data_sending` 置 1。GUI 端另外按 `frame_seq` 相同判定重复帧并丢弃，作为兜底。

---

## 4. 帧格式 v2（178 字节，大端）

| 偏移 | 字段 | 类型 | 说明 |
|---|---|---|---|
| 0–3 | 同步头 | `A5 5A A5 5A` | |
| 4–19 | ch1_x, ch1_y, ch2_x, ch2_y | 4 × int32 | PLL 锁相 X/Y（28 位符号扩展） |
| 20–43 | 振荡器 1~3 的 X/Y | 6 × int32 | 历史名 21/12/11 |
| 44–75 | 振荡器 4~7 的 X/Y | 8 × int32 | |
| 76–79 | ch3_dc | int32 | |
| 80–91 | adc_ch1/2/3 | 3 × int32 | 14 位符号扩展 |
| 92–107 | pll_freq_ch1/2_word | 2 × uint64 | 48 位频率字 |
| 108–111 | lock_flags | int32 | bit0 = ch1，bit1 = ch2 |
| 112–167 | ref_word × 7 | 7 × uint64 | 七路实际参考频率字 |
| **168–171** | **sample_cnt** | **uint32** | **FPGA 采样时间戳，1 LSB = 65 / F_CLK = 1 µs** |
| **172–175** | **frame_seq** | **uint32** | **帧序号** |
| **176–177** | **CRC16** | **uint16** | **CRC-16/CCITT-FALSE，覆盖第 0~175 字节** |

Python 解析参考：

```python
import binascii, struct
FRAME_LEN = 178
FRAME_FMT = ">19i3iQQi7QII"          # 第 4~175 字节
ok = binascii.crc_hqx(buf[:176], 0xFFFF) == int.from_bytes(buf[176:178], "big")
vals = struct.unpack(FRAME_FMT, buf[4:176])
```

---

## 5. GUI 改动细节

### 5.1 解析与重新对齐（`device.py`）

- `parse_frame()` 依次检查长度、同步头和 CRC，任何一项不通过都抛出 `ValueError`。
- `_rx_loop` 遇到校验失败的候选帧时，**只跳过这个同步头的第 1 个字节**后继续搜索，而不是丢掉整个 178 字节。命令打断造成的半帧后面紧跟的那一帧真数据因此不会被吞掉。

### 5.2 时间轴与丢帧（`FrameTracker`）

- `fpga_time_s` = (`sample_cnt` 展开值 − 首帧值) × `SAMPLE_TICK_S`，即相对开流首帧的 FPGA 采样时刻。
- `timestamp` = 首帧到达时的 PC 时间 + `fpga_time_s`。曲线和 CSV 都用它，不再受 USB 成批交付的影响。
- `sample_cnt` 回绕时自动展开；如果计数倒退（FPGA 复位或重新上电），会以当前帧重新起算。
- `frame_seq` 跳号累加到 `lost_frames`；与上一帧相同则计为重复帧并丢弃。

### 5.3 界面与 CSV（`main_window.py`）

- 状态栏：`收:… 显:… @…% 坏帧:N 丢帧:M`。其中"坏帧"是 CRC 失败的次数（含半帧），"丢帧"按序号跳号统计。
- CSV 新增列：`fpga_time_s`、`frame_seq`，紧跟在 `timestamp` 后面。
- CSV 文件头新增 `# frame_protocol` 和 `# SAMPLE_TICK_S` 两行。
- 停止数据流时，日志打印 CRC 坏帧、丢帧、重复帧的累计数。

### 5.4 删除的临时方案

`FrameClock`（时间戳平滑）和 `SpikeGuard`（统计法尖峰剔除）已删除，分别由 FPGA 时间戳和 CRC 取代。CRC 能检出任何字节错误，包括统计法分辨不出的低位字节错误。

---

## 6. 兼容性

| 组合 | 结果 |
|---|---|
| 新比特流 + 新 GUI | 正常 |
| 旧比特流（168 字节）+ 新 GUI | **没有数据**，状态栏"坏帧"持续快速增长 |
| 新比特流 + 旧 GUI | **没有数据**或解析错乱 |
| 以太网 UDP 通路（`eth_lockin_top`，目前在 `lock_in_amp.v` 中被注释掉） | **未适配**：它直接发送 `x_y_fir_packed`，既没有 `frame_seq` 也没有 CRC，且 `FRAME_BYTES` 仍为 80。重新启用前需要先补上，否则 `UdpLockinDevice` 会把所有包判为 CRC 错误 |
| `tools/host_*.py`、`lockin_gui/host_udp.py` 等调试脚本 | 仍是旧的 48/80 字节协议，没有更新 |

---

## 7. 构建与验证步骤

### 7.1 Vivado 构建

1. 打开 `project_1.xpr`。`lock_in_amp` 是 Block Design 的模块引用（module reference），源文件修改后 Vivado 会提示刷新，选择 **Refresh Changed Modules**。端口没有变化，刷新后不需要改连线。
2. 运行综合与实现，检查 **Timing Summary**：WNS ≥ 0。
   - 原工程的 WNS 只有 +0.457 ns，如果出现违例，重点看 `usb_commend` 中 `xy_data_reg` 的 176 选 1 字节选择器路径。
3. 生成比特流。如果软件侧需要，重新导出硬件（`design_1_wrapper.xsa`）。

### 7.2 上板验证清单

1. **应答**：在**未开数据流**时下发任意参数，日志应为 `Command Success!`，前面不能再出现多余的 `C`。
2. **坏帧**：全速开流 1~2 分钟，观察状态栏。
   - 坏帧应约等于 0（只在流模式下发命令时出现少量，属正常）。
   - 如果仍有约 2% 的坏帧，说明字节替换的根因在 FT245 硬件或 IO 时序，需要用 ILA 同时抓 `send_data`、`ft_wr`、`ft_d_out`、`ft_txe_n` 排查。此时数据本身已经被 CRC 保护，不会再出现尖峰。
3. **丢帧**：PC 负载正常时应接近 0。持续增长说明 PC 来不及读，或 USB 链路有问题。
4. **CSV**：全速录 10 秒，检查：
   - `fpga_time_s` 严格递增，相邻差值约等于"1 / 帧率"；
   - `frame_seq` 连续；
   - 对任一路 R 做频谱，102 Hz 及其倍频处不应再有假峰。

---

## 8. 已知限制与后续工作

- **时间基准**：`SAMPLE_TICK_S` 按标称 65 MHz 计算，没有乘时基标定系数 `CLK_CAL`。如果晶振偏差为 x ppm，`fpga_time_s` 也偏 x ppm；绝对时间 `timestamp` 相对 PC 时钟会缓慢漂移（每 100 ppm 约 0.36 s/h）。
- **帧长与帧率**：帧长由实际发送的 169 字节（含之前多发的那个字节）变为 178 字节，帧率约降低 5%。
- **字节替换的根因**未确认，CRC 只能发现并丢弃坏帧，不能消除。
- **未在本次处理的 GUI 问题**：
  - 录制 CSV 时抽样默认值是 10%，且录制过程中仍可修改；
  - CSV 后台写盘线程遇到异常会静默退出；
  - 流模式下"一键下发"命令之间没有间隔，可能丢命令字节；
  - 停流后没有清空串口输入缓冲，残留的帧字节可能干扰下一条命令的应答。
- `docs/Interface_Spec_for_SW.md` 第 3.3 节仍是旧协议，已在该节加了指向本文的提示。
