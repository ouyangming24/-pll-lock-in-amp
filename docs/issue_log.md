# 问题日志 (Issue Log)

本文档用于持续记录工程开发中遇到的**所有问题** —— 包括 FPGA RTL、
PCB / IO 物理层、上位机 GUI、网络通信、协议、综合工具链等。

## 格式约定

每条记录用一个 `## ` 二级标题，按**时间倒序**排列（最新的在最上面）。

每条必须包含：

| 字段 | 说明 |
|---|---|
| **发现日期** | YYYY-MM-DD |
| **关联模块/层** | RTL / PCB / GUI / 协议 / 工具链 / 其他 |
| **现象** | 用户看到的可观察现象 (越具体越好) |
| **排查过程** | 试过哪些方向, 走错过的弯路也记一下 (后人不踩坑) |
| **根因** | 真正的原因 (若已定位) |
| **修复** | 怎么解决的, 代码/约束/硬件改动 |
| **状态** | ✅ 已解决 / ⚠ 部分解决 / ❌ 未解决 / 🔍 调查中 |
| **关联文件** | 涉及到的源码/约束/文档路径 |
| **备注** | 经验教训、未来要注意的事 |

新增条目时, 从下面的"条目模板"复制即可。

---

## 条目模板 (复制用)

```markdown
## YYYY-MM-DD · 一句话标题

- **发现日期**: YYYY-MM-DD
- **关联模块/层**: 
- **现象**: 
- **排查过程**: 
- **根因**: 
- **修复**: 
- **状态**: 🔍 调查中
- **关联文件**: 
- **备注**: 
```

---

## 2026-09-23 · BD OOC 双 IOBUF 导致 wrapper 串口全 Command Error

- **发现日期**: 2026-09-23
- **关联模块/层**: 工具链 / RTL (`lock_in_amp` inout FT245) / 固化 BD
- **现象**: 独立 `lock_in_amp.bit` 指令正常；`design_1_wrapper.bit` 一律回 `Command Error!`，GUI 无法连接。
- **根因**: `lock_in_amp` 作为 BD module_ref 被 Hierarchical/OOC 综合，内部 `assign ft_d = oe ? tx : 8'bz` 在 IP 边界推断 IOBUF，wrapper 再推断一层 → 读总线错乱。
- **修复**: `design_1.bd` 的 `synth_flow_mode` / `synth_checkpoint_mode` 改为 **None（Global）**，Reset Runs 后重出 bit。module_ref 的 `generate_synth_checkpoint` 只读，不必改。
- **状态**: ✅ 已解决
- **关联文件**: [完整说明](./BD_OOC_双IOBUF_USB命令Error.md)、`fix_bd_ooc_ft245.tcl`、`design_1.bd`、`pin_solidify.xdc`
- **备注**: 带 inout 三态的模块不要 OOC；出问题先对比独立顶层 vs wrapper。

---

## 2026-06-11 · 光弹应力 GUI / 验算脚本

- **发现日期**: 2026-06-11
- **关联模块/层**: GUI (`stress_calc.py`, `main_window.py`, `stress_manual_gui.py`)
- **现象**:
  1. 按 `1119修正计算公式.md` 接入四路电压 → ρ/δ 后，δ 公式选用存在歧义（文档 acos 形式 vs 工程 atan 形式）。
  2. `stress_manual_gui.py` 启动报 `NameError: name 'root' is not defined`。
  3. Windows 控制台打印含 ρ、² 等字符时可能 `UnicodeEncodeError`。
- **根因**:
  - 式 9.2 在文档中以 `acos(R3/R_fix)` 出现，但完整推导等价于 `δ = atan(sqrt((R1/R3)²+(R2/R3)²))`；实现选 atan 形式。
  - GUI 类中使用了 `root` 但未 `root = QWidget()`。
  - 控制台默认 GBK 编码不支持部分 Unicode 符号。
- **修复**:
  1. `stress_calc.py`: R_fix 按式 8.1–8.3；ρ 用 `0.5·atan2(R2,R1)`；δ 用 `atan(hypot(R1/R3,R2/R3))×316.4/π` nm。
  2. `main_window.py`: 应力面板（Offset 捕获、四路 K、实时 ρ/δ）；幅值显示 ≥1V→V、≥1mV→mV、否则 µV。
  3. `stress_manual.py` / `stress_manual_gui.py`: 独立验算工具；补 `root = QWidget()`；CLI 输出改用 ASCII。
- **状态**: ✅ 已解决 (应力为纯上位机计算, 不改 FPGA)
- **关联文件**:
  - `lockin_gui/stress_calc.py`, `lockin_gui/main_window.py`
  - `lockin_gui/stress_manual.py`, `lockin_gui/stress_manual_gui.py`
  - `1119修正计算公式.md`
- **备注**: 若需 GUI 切换 acos/atan 两种 δ 公式, 需再改 `stress_calc.py`。

---

## 2026-06-11 · DAC 信号源改为振荡器本振 + 幅值/偏置 (DMOD/DAMP/DOFS)

- **发现日期**: 2026-06-11
- **关联模块/层**: RTL + GUI + 协议
- **现象 / 动机**:
  原 DAC 用独立 `dds_compiler_1` + `DFRQ/DPHS`, 与三路振荡器解调参考不同源, 跟随模式下易出现相位差/杂波;
  用户要求 DAC 可选振荡器1/2/3 本振, 且幅值/偏置可调 (满量程约 ±3V)。
- **修改**:
  1. `lockin_psd.v`: 新增 `ref_sine_o` 输出本振正弦 (与混频同源)。
  2. `lock_in_amp.v`: 删除独立 DAC DDS; `dac_ref_sin` mux 三路 `osc_ref_sin_*`; `DAMP` 16bit 缩放 + `DOFS` 14bit 偏置 + 饱和。
  3. `usb_commend.v`: `DMOD` 改为 0/1/2=振荡器1/2/3; 新增 `DAMP`/`DOFS`; `DFRQ`/`DPHS` 保留解析但硬件废弃。
  4. GUI: 信号发生器面板同步。
- **状态**: ✅ 已实现 (待上板确认 DAC 波形与解调同相)
- **关联文件**:
  - `project_1.srcs/sources_1/new/lock_in_amp.v`, `lockin_psd.v`, `usb_commend.v`
  - `lockin_gui/main_window.py`, `docs/UART_Protocol.md`
- **备注**:
  - **勿每拍重配 DDS** — 跟随模式应直接复用 PSD 本振, 不要另开 DDS 扫频。
  - 早期独立 DAC DDS 曾导致 WNS 恶化与 GUI 发帧异常 (见 2026-06-08 条目)。

---

## 2026-06-11 · 振荡器谐波阶数 N (OHN1/2/3) + Verilog 语法

- **发现日期**: 2026-06-11
- **关联模块/层**: RTL + GUI + 协议
- **现象**:
  综合报错: 对 `(f_base * oh)[47:0]` 做位选 — Vivado 不支持对复杂表达式直接位选。
- **根因**: Verilog-2001 要求位选操作数必须是明确 wire/reg, 不能是 `(a*b)[47:0]`。
- **修复**:
  - `lock_in_amp.v`: `wire [63:0] f_harm_xx = f_base_xx * ohN_eff`, 再 `ref_freq <= f_harm_xx[47:0]`。
  - `coherent_harm_lo.v`: `wire [55:0] comb_prod = comb_sum * order_eff`, 再赋 `comb_phase`。
  - 命令 `OHN1/2/3`, 默认 N=1, 最终 `f_ref = f_base × N` (类 Zurich)。
- **状态**: ✅ 已解决
- **关联文件**: `coherent_harm_lo.v`, `lock_in_amp.v`, `usb_commend.v`, `main_window.py`

---

## 2026-06-11 · CH4/OSRC 后时序违例 + 多模块功能异常

- **发现日期**: 2026-06-10 ~ 2026-06-11
- **关联模块/层**: RTL / 时序 / XDC
- **现象**:
  1. 新增 CH4、`OSRC1/2/3` (CH3/CH4/差分) 后 Implementation **WNS 为负** (约 -3.6 ns 量级)。
  2. 时序“修一点”后 oscill2/3 或 DAC 仍异常: 锁定值不对、某路恒 0、DAC 输出杂波而非正弦。
  3. 有时 PLL 正常但振荡器/信号发生器仍坏。
- **排查过程**:
  1. 先怀疑 GUI 命令未下发 — 加帧内 `ref_word_*` 回读 (104B 帧) 核对。
  2. 发现 failing path 在 ADC→差分→mux→PSD 长组合链, 以及 435 bit 配置 CDC。
  3. 注释 ILA 释放布线; 对 `coherent_harm_lo`、PLL 相位、OSRC mux 加流水。
- **根因**:
  - CH4 差分 + 三路 OSRC mux 拉长 65M 域组合路径。
  - `usb_commend` 在 50M、`x_y_fir_packed`/配置在 65M, **640 bit 数据 + 宽配置总线 CDC** 不可靠。
  - DAC 独立 DDS 每拍 `tvalid=1` 加重 65M 拥塞。
- **修复** (当前源码):
  1. **FT245 + `usb_commend` 迁到 `clk_65M`**, 配置与 `x_y_fir_packed` **同域直连, 删除 435 bit CDC**。
  2. OSRC: `adc_diff_sat_r` + `adc_in_osc*` **两级寄存** (lock_in_amp.v ~339–378)。
  3. `coherent_harm_lo`: 乘加 ×N **三级流水**; `f_base×N` 用 wire 承接。
  4. DAC: 改接 `ref_sine_o`, 去掉独立 DDS 重配。
  5. ILA 暂时注释减布线压力。
- **状态**: ⚠ 部分解决 — 2026-06-10 用户确认三路+DC 正常; CH4/OHN/DAC 改版后需 **重新综合上板** 再验
- **关联文件**:
  - `lock_in_amp.v`, `ft245_rx.v`/`ft245_tx.v` (时钟改为 65M)
  - `coherent_harm_lo.v`, `pin.xdc` / 时序约束
- **备注**:
  - 加并行 ADC 路径时 **先加 pipeline 再扩功能**, 不要堆组合逻辑后靠 phys_opt 硬挤。
  - 帧格式现为 **104 字节** (含 3×ref 频率字回读), GUI `device.py` 须同步。

---

## 2026-06-10 · 振荡器2/DC 恒为 0、三路锁定值不一致

- **发现日期**: 2026-06-09 ~ 2026-06-10
- **关联模块/层**: RTL (CDC / 时序) + GUI
- **现象**:
  100 kHz 同相信号输入, 手动模式三路设相同频率: osc1/3 跳变但幅值不同, **osc2 与 DC 恒为 0**;
  改 osc2 频率无任何响应。后确认 **完整重烧** 后三路+DC 恢复正常。
- **排查过程**:
  1. 排除 GUI 换算 — 命令格式对称。
  2. 帧内追加 `ref_word_21/12/11` 回读, 区分“命令未到”vs“PSD 坏了”。
  3. 定位到 **65M↔50M 配置/数据 CDC**: 宽总线单级同步导致部分字段采到旧值/0。
- **根因**:
  跨时钟域 **多 bit 配置** (OSC/FRQ/REFMODE 等) 未稳定同步 → 某路 `ref_freq` 实际为 0 → sin(0) 混频输出恒 0。
  DC 恒 0 在纯交流输入下正常; 若加直流仍 0, 可能是 **模拟前端交流耦合** (待硬件确认)。
- **修复**:
  - XDC: `sys_clk` 与 `clk_65M` **异步分组** + 配置总线 **两级同步** (后演进为整域迁 65M)。
  - `f_osc*_auto`、`coherent_harm_lo` 加流水打断长路径。
  - 数据帧 80→**104 字节**, 带回读字段。
- **状态**: ✅ 已解决 (2026-06-10 用户确认)
- **关联文件**: `lock_in_amp.v`, `lockin_gui/device.py`, `usb_commend.v`
- **备注**: “改了 RTL 但现象不变” 多次是因为 **未烧录最新 bitstream**。

---

## 2026-06-10 · 自动模式相干本振 — 上电/切模式后 Θ 随机

- **发现日期**: 2026-06-09 ~ 2026-06-10
- **关联模块/层**: RTL (lockin_psd / lock_in_amp)
- **现象**:
  CH1 DAC 跟随与外参考 **同频同相**; 但振荡器自动模式 (如 1F1+0F2) 锁同源信号时 **Θ 每次上电/切模式变化**,
  三路设相同系数时 **Θ/幅值仍不一致**。
- **根因**:
  自动模式原先用 **独立 DDS + 仅借频率字**, 相位与 PLL 本振 **不相干**; 各 PSD 实例 DDS 自由积分, 初相随机。
- **修复**:
  - 新增 `coherent_harm_lo.v`: `θ_harm = N·(n·θ1 + m·θ2)`, 用 PLL 相位字驱动, `increment=0`。
  - `lockin_psd`: `use_coh_ref` 时混频用相干 sin/cos, 不再仅 sync 频率字。
  - 自动模式 GUI **停止** 每帧重算下发 FRQ (硬件实时运算)。
- **状态**: ✅ 已解决 (相干本振 + 流水后上板验证通过)
- **关联文件**: `coherent_harm_lo.v`, `lockin_psd.v`, `lock_in_amp.v`, `main_window.py`

---

## 2026-06-08 · 添加 DAC 后 GUI 串口无数据 + 严重时序违例

- **发现日期**: 2026-06-08
- **关联模块/层**: RTL / 时序
- **现象**:
  新增 DAC904 (`u_dds_dac` + `da_wave_send`) 后, `--serial` 模式 **XYOUT 有应答但 FPS=0**;
  timing 报告 **WNS ≈ -10 ns**, 1831 failing endpoints。
- **根因**:
  第 3 个 `dds_compiler_1` + DAC mux 加重 **65M 域**; USB 触发 `dc_valid_x_ch1` 在 65M 仅 1 拍,
  经 50M `usb_commend` 采样易漏 (次要); 主因是 **整体时序崩溃** 导致发帧/state 机异常。
- **修复**:
  - 短期: 回退无关改动, 确认 DAC 提交引入违例; DAC DDS **`tvalid` 脉冲化** + 配置寄存。
  - 长期: 见 2026-06-11 条目 (USB 迁 65M、DAC 改振荡器本振)。
- **状态**: ✅ 已解决 (后续架构调整)
- **关联文件**: `lock_in_amp.v`, `project_1.runs/impl_1/*timing*`
- **备注**: `usb_commend.v` 新增 DMOD/DFRQ/DPHS **不改动发帧 FSM**, 不是 FPS=0 根因。

---

## 2026-06-08 · DAC 输出频率固定 ~88 kHz 不随设置变化

- **发现日期**: 2026-06-08
- **关联模块/层**: RTL + GUI
- **现象**: GUI/命令改 DFRQ 或跟随 CH1, 示波器测 DAC **始终 ~88 kHz**。
- **排查过程**:
  查 `dac_src_mode` mux、`pll_freq_ch1` 接线、GUI `hz_to_freq_word` 与 `_clk_cal`。
- **根因** (当时独立 DAC 方案):
  - 跟随模式仍走内部 DDS 默认频率字; 或 `s_axis_config_tvalid` 恒 1 时 DDS IP 行为异常;
  - 时序违例导致 mux/配置字采样错乱。
- **修复**: 后改为 **直接 mux 振荡器 `ref_sine_o`**, 从根本去掉独立 DAC 频率链。
- **状态**: ✅ 已解决 (架构替换)
- **关联文件**: `lock_in_amp.v`, `main_window.py`

---

## 2026-05-12 · 数据帧扩展 80 → 104 字节 (参考频率回读)

- **发现日期**: 2026-06-10 (诊断引入)
- **关联模块/层**: RTL + 协议 + GUI
- **现象**: 需确认硬件实际使用的 `ref_freq_*`, 旧 80B 帧无此字段。
- **修改**:
  - 帧尾追加 `ref_word_21/12/11` 各 64bit (48bit 频率字); `FRAME_BYTES=104`。
  - `device.py`: `FRAME_FMT = ">11i3iQQi3Q"`, `FRAME_LEN=104`。
  - GUI 振荡器旁显示 `硬件=xxx Hz`。
- **状态**: ✅ 已实现 (USB/UDP 路径均用同一打包)
- **关联文件**: `lock_in_amp.v`, `usb_commend.v`, `lockin_gui/device.py`, `docs/Interface_Spec_for_SW.md`
- **备注**: 改帧格式后 **必须同时更新 FPGA + GUI**, 否则解析全错。

---

## 2026-05-12 · 串口 vs UDP 数据不一致 (USB 路径无数据 CDC)

- **发现日期**: 2026-05-12
- **关联模块/层**: RTL (CDC) / 协议
- **现象**: 同一板卡 **UDP 模式数据正常**, **串口模式** 频率/锁定值乱跳或不可信。
- **根因**:
  - UDP: `x_y_fir_packed` 经 **XPM_FIFO_ASYNC** 65M→125M ✓
  - USB: `usb_commend` 在 **50M** 直接采样 **65M** 域的 640bit `x_y_fir` 与 `dc_valid` **无 FIFO** ✗
- **修复**: 2026-06-11 将 FT245 + `usb_commend` **整体迁到 clk_65M**, 与锁相核心同域。
- **状态**: ✅ 已解决
- **关联文件**: `lock_in_amp.v`, `eth_lockin_top.v`
- **备注**: 若保留双上行, 应对 USB 数据也使用 async FIFO, 而非裸 CDC。

---

## 2026-05-12 · PLL 锁定阈值过高导致扫频/锁定反复横跳

- **发现日期**: 2026-05-12
- **关联模块/层**: RTL + GUI + 协议
- **现象**: 频率显示抖动、难锁定; 或 weak 信号下 **SWEEP↔LOCK 来回跳**。
- **根因**: `SWEEP_THRES`/`LOCK_X_THRES` 原为综合时常量 (曾用 800K/3M), 对中等信号过严。
- **修复**:
  - `pll_controller.v`: 阈值改为 **input wire**。
  - 命令 **`LOCKSWY`** (Y 进 LOCK)、**`LOCKTHX`** (X 维持 LOCK); 默认 **100K / 300K**。
  - GUI 新增阈值面板; 文档 `UART_Protocol.md` 6.3.9/6.3.10。
- **状态**: ✅ 已解决
- **关联文件**: `pll_controller.v`, `pll_loop.v`, `usb_commend.v`, `lock_in_amp.v`, `main_window.py`
- **备注**:
  - SWEEP 只看 **|dc_y|**, LOCK 只看 **|dc_x|** — 顺序不可颠倒。
  - 商用产品常用 **R=√(X²+Y²)** 判据, 后续可改进。

---

## 2026-05-12 · 电压标定: 实测 vs 苏黎世 + 峰值/RMS 显示

- **发现日期**: 2026-05-12
- **关联模块/层**: GUI
- **现象**:
  1. 输入 Vpp=40mV (Vp=20mV) GUI 显示 ~10mV; Vpp=400mV 显示 ~104mV (~0.52×)。
  2. 与苏黎世对比, 需 ×**0.9966** 才一致。
  3. 用户要求 **峰值 / RMS** 显示可切换。
- **根因**:
  - 显示量为 **峰值 (R/|X|)**, 非 RMS; 旧 `MV_PER_LSB` 公式仍有 ~2× 量级偏差 (见 2026-05-11 条目)。
  - 前端增益/ADC 有效位数与理想 ±5V 满量程有偏差。
- **修复**:
  - 推导链修正 + GUI **`CALIB_K`** (谐波) 与 **`CALIB_K_DC`** (直流) **分开**。
  - 新增峰值/RMS 切换; 苏黎世对标值作默认 `CALIB_K` 初值。
- **状态**: ⚠ 部分解决 — 公式已修正, 仍需实测微调 K
- **关联文件**: `lockin_gui/main_window.py`

---

## 2026-05-12 · 直流 (DC) 通路显示偏小

- **发现日期**: 2026-05-12
- **关联模块/层**: GUI
- **现象**: DC 读数比预期小约 **4096 倍** (2^12)。
- **根因**: DC 通路 `adc→CIC→IIR` 输出 LSB 与谐波通路混频后增益链 **未乘同一 front-end 系数**。
- **修复**: GUI 侧 DC 换算使用 **`G_TOTAL_DC`** (或独立 `CALIB_K_DC`), 与谐波分开标定。
- **状态**: ✅ 已解决 (GUI 标定)
- **关联文件**: `lockin_gui/main_window.py`

---

## 2026-05-06 ~ 2026-05-08 · 千兆以太网 UDP 上行迁移

- **发现日期**: 2026-05-06 ~ 2026-05-08
- **关联模块/层**: RTL / 网络 / 工具链 / 上位机
- **现象** (摘要): 综合报错 (错误文件路径、`udp_complete` 端口、`BUFIO`)、RGMII RX 需 IDELAY、
  TX 物理层不通、子网与 **192.168.1.x 冲突**、代理软件劫持 UDP、`ping` 超时 (无 ICMP)、上电 ~50s IDELAY 扫描无数据等。
- **结果**: ✅ 调通 — GUI `--udp` 模式; 命令仍走 FT245, 数据走 UDP。
- **详细复盘**: 见 [`docs/ethernet_migration_retrospective.md`](ethernet_migration_retrospective.md)
  (坑 #1–#18: Tcl `[pwd]` 非工程目录、子网改 **192.168.99.0/24**、`USE_CLK90`、IDELAY 扫描等)。
- **关联文件**:
  - `eth_lockin_top.v`, `udp_lockin_tx.v`, `eth_phy_init.v`, `eth_pins.xdc`
  - `lockin_gui/device.py` (`UdpLockinDevice`), `tools/host_udp.py`
- **备注**:
  - 应用层帧率 ~**3.6 kbps** (受 `dc_valid` 节流), 非千兆瓶颈。
  - **不要用 ping** 测 FPGA; 用 `arp -a` + UDP 收帧。

---

## 2026-05-11 · 通道3 IIR 阶数从"全局统一"细分为"每路独立" (ORDER → ORD21/ORD12/ORD11/ORDDC)

- **发现日期**: 2026-05-11
- **关联模块/层**: RTL (usb_commend.v, lock_in_amp.v) + GUI + 协议
- **现象 / 动机**:
  上一版用单条 `ORDER` 命令让 3 路谐波 + DC 共享同一阶数 (类似 SR830 的全局 Filter Slope).
  用户要求每路独立设置阶数 (类似 SR860 / Zurich MFLI 的 per-channel slope),
  以应对"某些谐波信号弱需要 24 dB/oct, 另一些信号强只需要 6 dB/oct"的混合场景.
- **修改**:
  1. **`usb_commend.v`**:
     - 删除单一 `output reg [2:0] iir_order`, 改成 4 个独立输出: `order21/order12/order11/order_dc`.
     - 删除 `CMD_ORDER`, 新增 `CMD_ORD21/CMD_ORD12/CMD_ORD11/CMD_ORDDC` (5'd25..28).
     - 5 字符命令解析分支拆成 4 个独立判断 (与 TAU21/12/11/DC 风格一致).
     - REC_DATA 分支 4 个独立钳位逻辑 (1..4, 非法视为 1).
  2. **`lock_in_amp.v`**:
     - wire `iir_order_uart` 拆成 `order21_uart/order12_uart/order11_uart/order_dc_uart`.
     - 3 路 `u_psd_ch3_21/12/11` 分别接对应 wire.
     - DC 通路 `u_iir_dc_ch3` 接 `order_dc_uart`.
     - `u_usb_commend` 端口连接相应调整.
  3. **GUI (`main_window.py`)**:
     - 删除单一 `cb_order`, 新建独立子分组 "IIR 阶数 (CH3 各路独立)" 含 4 个下拉框.
     - 新增 `_mk_order_row` 辅助函数 + `_send_order_one` 通用下发函数.
     - 保留**便捷功能**: "快捷统一" 下拉框 + ▶ 按钮, 一键把 4 路设为相同阶数
       (满足用户"大多数时候我希望统一调"的场景, 同时支持精细化分别调).
  4. **`device.py`**: MockDevice 删 "ORDER", 加 "ORD21/ORD12/ORD11/ORDDC" 各默认 1.
  5. **`UART_Protocol.md`**: 6.2.1 指令一览表 1 行变 4 行, 重写 6.3.8d 章节,
     更新大小写敏感清单.
- **状态**: ✅ 已实现 (待综合验证)
- **关联文件**:
  - `project_1.srcs/sources_1/new/usb_commend.v`
  - `project_1.srcs/sources_1/new/lock_in_amp.v`
  - `lockin_gui/main_window.py`
  - `lockin_gui/device.py`
  - `docs/UART_Protocol.md`
- **备注**:
  - RTL 资源代价不变 (cascade 模块内部本来就是 4 级硬件, 只是 mux 选择哪一级输出).
  - X/Y 共用同一个 order (与 SR830 设计一致), 保证复数信号 X+jY 对称滤波.
  - "快捷统一" 按钮设计原因: 用户日常切档时大多希望统一调, 把 4 路独立设置
    保留为"高级"功能, 不强制每次都点 4 下.

---

## 2026-05-11 · 通道3 IIR 滤波器支持运行时可调阶数 (1~4 阶级联, 仿 SR830)

- **发现日期**: 2026-05-11
- **关联模块/层**: RTL (iir_lpf_cascade.v, lockin_psd.v, lock_in_amp.v, usb_commend.v) + GUI + 协议
- **现象 / 动机**:
  原 `iir_lpf_ema` 是 1 阶单极点 IIR (6 dB/oct), 工业锁相放大器 (如 SR830/SR860)
  提供 6/12/18/24 dB/oct 多档可选, 用户希望 GUI 中能像 SR830 一样切换滤波器阶数,
  以便在"低噪声"与"快建立时间"之间动态权衡.
- **设计选型**:
  - **不用巴特沃斯**: 巴特沃斯阶跃响应有过冲, 不利于稳态测量, 且 FPGA 实现复杂.
  - **采用 N 个相同 tau 的 EMA 级联**: 与 SR830/SR860 同结构, 单调收敛无振铃,
    资源极省 (复用现有 EMA), tau 含义不变, 用户只需多选一个"阶数".
  - **运行时可选阶数**: 内部例化 4 个 EMA, 用 mux 选第 N 级输出. 默认 N=1
    (完全兼容原行为).
  - **PLL 通道不参与**: PLL 反馈环对相位裕度敏感, 多阶级联会破坏稳定性.
    仅 CH3 的 3 路 PSD + DC 通路支持 ORDER 控制.
- **修复 / 实现**:
  1. **新建 `iir_lpf_cascade.v`**: 内部 4 个 `iir_lpf_ema` 级联, mux 选第 1..4 级输出.
     非法 order 值视为 1 阶 (向后兼容).
  2. **`lockin_psd.v`**: 把 `iir_lpf_ema` 替换为 `iir_lpf_cascade`, 新增 `iir_order` 输入端口.
  3. **`lock_in_amp.v`**:
     - 新增 wire `iir_order_uart`.
     - 3 路 `u_psd_ch3_21/12/11` + DC 通路 `u_iir_dc_ch3` 全部接到 `iir_order_uart`.
     - DC 通路也从 `iir_lpf_ema` 换为 `iir_lpf_cascade` (与谐波路径一致).
  4. **`usb_commend.v`**: 新增 `ORDER` 命令 (5 字符), 解析时钳位到 1..4, 默认 1.
     输出 `iir_order [2:0]`.
  5. **GUI (`main_window.py`)**: "IIR 滤波时间常数" group 新增 `QComboBox`,
     选项 "1 阶 (6 dB/oct)" / "2 阶 (12 dB/oct)" / "3 阶 (18 dB/oct)" / "4 阶 (24 dB/oct)".
     "一键下发" 流程中加入 `_send_order_cmd()`.
  6. **`device.py`**: MockDevice 加 "ORDER": 1 默认参数.
  7. **协议文档**: `docs/UART_Protocol.md` 6.2.1 指令一览表新增 ORDER, 新增 6.3.8d 章节
     详细解释原理 / 实现 / 与 tau 的关系 / PLL 不参与的原因.
- **资源代价 (估算)**:
  - 单个 `iir_lpf_cascade` 比 1 阶 EMA 多 3 个 EMA 实例 ≈ +600 LUT + 180 FF.
  - 全工程: 3 路 PSD (X+Y, 共 6 个 cascade) + 1 个 DC cascade = 7 个 cascade,
    增量 ≈ +4200 LUT + 1300 FF.
  - Zynq-7020 (53k LUT) 富余 > 90%, 完全可承受.
- **状态**: ✅ 已实现 (待综合 + 仿真验证)
- **关联文件**:
  - `project_1.srcs/sources_1/new/iir_lpf_cascade.v` (★ 新增)
  - `project_1.srcs/sources_1/new/lockin_psd.v` (修改)
  - `project_1.srcs/sources_1/new/lock_in_amp.v` (修改)
  - `project_1.srcs/sources_1/new/usb_commend.v` (新增 CMD_ORDER 解析)
  - `lockin_gui/main_window.py` (新增 cb_order + _send_order_cmd)
  - `lockin_gui/device.py` (MockDevice.params 加 ORDER)
  - `docs/UART_Protocol.md` (6.2.1 + 6.3.8d)
- **备注**:
  - 阶数越高建立时间越长 (≈ N · τ_单阶), 用户应根据动态响应需求调整.
  - 后续若要给 PLL 通道也加阶数控制, 需要再引入 `pll_iir_order` 参数 (不要复用 ORDER).
  - 如果将来要让每个通道单独设阶数, 可以扩展为 ORDER21 / ORDER12 / ORDER11 / ORDERDC
    四条命令, RTL 端把 `iir_order` 端口拆成 4 个.

---

## 2026-05-11 · GUI 电压换算系数严重偏小 (~4.6 倍)

- **发现日期**: 2026-05-11
- **关联模块/层**: GUI (lockin_gui/main_window.py)
- **现象**:
  GUI 显示的 X/Y/R 电压值 (mV) 比真实输入小约 4.6 倍.
  原因是 `MV_PER_LSB` 是凭"假设 ADC 量程 1V"猜的, 没考虑实际硬件.
- **排查过程**:
  1. 用户确认 ADC 模拟输入量程是 ±5V (不是假设的 1V), 偏差因子 5×.
  2. 打开 `cic_compiler_0.xci` 读 CIC IP 配置:
     R=65, M=1, N=5, Quantization=Truncation, 输入/输出 28 bit.
  3. Truncation 模式下 CIC 实际增益 = (R·M)^N / 2^growth
     = 65^5 / 2^31 ≈ 0.5403 (略有衰减, 不是放大), 而非默认假设.
  4. 完整信号链推导:
     G_total = (2^13 / V_FS) × 2^13 × 0.5 × G_cic
             = (8192/5) × 8192 × 0.5 × 0.5403
             ≈ 3,626,240
     → MV_PER_LSB = 1000 / G_total ≈ 2.758e-4 mV (旧值 5.96e-5, 偏小 4.62 倍)
- **根因**:
  原 `MV_PER_LSB = 1000 / 2^24` 没基于硬件参数. ADC 量程从 1V → 5V 差 5×,
  CIC 真实增益 0.5403 但旧代码暗含的有效增益是 2^11 ≈ 2048, 差很多.
- **修复**:
  1. `main_window.py` 顶部新增模块级常量, 详细写出信号链推导:
     - `ADC_FS_V = 5.0` (ADC 量程)
     - `CIC_R/M/N` (CIC IP 参数, 与 .xci 文件锁定一致)
     - `CIC_GAIN_EFF`, `G_TOTAL` 计算公式
     - `CALIB_K = 1.0` 留作实测标定修正用
     - `V_PER_LSB` / `MV_PER_LSB` 统一从公式推出
  2. 两处局部硬编码常量删除, 统一用模块级.
- **状态**: ✅ 已解决 (理论值; 仍需实测标定确认)
- **关联文件**:
  - `lockin_gui/main_window.py` 顶部 80~100 行 (电压换算常量段)
  - `project_1.srcs/sources_1/ip/cic_compiler_0/cic_compiler_0.xci` (CIC IP 配置)
- **后续标定建议**:
  - 在 ADC 输入注入 已知幅度正弦波 (例如函数发生器 100 mV 峰值 @ 50 kHz)
  - GUI 上看 R 的稳态显示值
  - 若 R = 100 mV 完美对上, 不用改; 若偏差 ±10% 以内, 改 `CALIB_K` 微调
  - 若偏差 > 50%, 检查 ADC 前端电路是否有未计入的放大/衰减
- **未来教训**:
  - 凡是"假设 ADC 满量程 1V"这种关键参数, 都要靠注释和代码硬编码记录,
    最好和硬件原理图标号对齐. 这次教训: 一个不起眼的常量错位影响整个数据可信度.
  - 信号链增益不能拍脑袋, 必须沿"adc → mix → cic → iir" 一步步推导.
  - CIC IP 的 Truncation 模式实际是"衰减"不是"放大", 容易反直觉.

---

## 2026-05-11 · 通道3 ref_freq 来源开关 (REFMODE) 硬件 mux 预埋

- **发现日期**: 2026-05-11
- **关联模块/层**: RTL (lock_in_amp.v, usb_commend.v) / 协议 (UART)
- **现象**: 这不是 bug, 是一个"预留通道". 软件端已经实现"自动 (跟随 F1/F2) / 手动"
  两种 ref_freq 模式. 但软件"自动"是 PC 每帧重算 + 下发, 有延迟. 未来 PLL 恢复后,
  应该用 FPGA 硬件实时运算 (无延迟). 现在提前把硬件 mux 写好, 等 PLL 恢复时启用.
- **改动**:
  1. `usb_commend.v` 新增 1-bit 输出端口 `ref_freq_auto` + 命令 `REFMODE` (cmd_cnt==7 分支).
  2. `lock_in_amp.v` 新增 `ref_freq_21/12/11_to_psd` 3 个 wire +
     三元 mux (`ref_freq_auto_uart ? f_2f1_plus_f2 : freq_word_21_uart`).
  3. 因为 PLL 模块还注释着, `pll_freq_ch1/ch2` 是悬空 wire,
     mux 的"自动支路"会引用悬空信号 → 综合不会出错但运行结果不可预测.
     因此 mux **现阶段强制走手动支路** (3 行 `assign ref_freq_xx_to_psd = freq_word_xx_uart;`),
     mux 的真正自动支路被注释保留, PLL 恢复后取消注释即可生效.
  4. 协议文档 `UART_Protocol.md` 6.3.8c 节同步更新.
- **状态**: ✅ 已完成 — PLL 已恢复 (2026-05-12 起); 硬件自动支路 `coherent_harm_lo` + `REFMODE:1` 已启用; GUI 自动模式不再每帧下发 FRQ
- **关联文件**:
  - `project_1.srcs/sources_1/new/usb_commend.v` (新增 REFMODE 命令)
  - `project_1.srcs/sources_1/new/lock_in_amp.v` (ref_freq mux + coherent_harm_lo)
  - `project_1.srcs/sources_1/new/coherent_harm_lo.v` (★ 2026-06 新增)
  - `docs/UART_Protocol.md` (新增 6.3.8c)
- **PLL 恢复后激活清单** (归档, 均已完成):
  - [x] 取消 `pll_loop u_pll_ch1` / `u_pll_ch2` 实例化注释
  - [x] 启用硬件自动 ref_freq / 相干本振 (非 GUI 重算下发)
  - [x] USB 数据触发改回 `dc_valid_x_ch1` (同域 65M, 无 CDC 漏采)
  - [x] 重新综合 + 烧写
  - [ ] 上位机发 `REFMODE:1` 验证 — 常规测试项

---

## 2026-05-11 · USB 串口模式下 GUI 完全收不到数据帧 (PLL 注释副作用)

- **发现日期**: 2026-05-11
- **关联模块/层**: RTL (lock_in_amp.v) / 协议
- **现象**:
  GUI 用 `python main.py --serial` 启动, 串口 COM6 连接成功, `XYOUT`
  命令也收到 "Command Success!" 应答, **但 GUI 完全没有任何数据帧显示**,
  PLL 状态恒为 UNLOCKED, 所有波形为空白. UDP 模式同样不发数据 (相同根因).
- **排查过程**:
  1. 先验 GUI 路径: `LockinDevice._rx_loop` 在搜 `\xA5\x5A\xA5\x5A` 头,
     `FRAME_LEN = 80`, 解析格式 `>11i3iQQi` —— 与 RTL 端打包完全一致.
  2. 再验 `usb_commend.v` 发送侧: `FRAME_BYTES = 80`, send 状态机正常,
     发送被 `xy_data_enable && m_axis_data_tvalid_fir_x_posedge` 触发.
  3. 跟踪 `m_axis_data_tvalid_fir_x` 端口连接到 lock_in_amp.v 第 451 行的
     `dc_valid_x_ch1` —— **发现 `pll_loop u_pll_ch1` 整段实例化被注释了**
     (用户为单独验证锁相放大器而临时注释 PLL/以太网模块),
     导致 `dc_valid_x_ch1` 是悬空 wire.
  4. 结论: 悬空 wire 永无上升沿 → `xy_data_reg` 永远不被加载 →
     80 字节数据帧永远不会发出 → GUI 搜不到任何同步头.
- **根因**:
  USB 数据帧的"开始打包"触发信号 (`dc_valid_x_ch1`) 依赖被注释的
  `pll_loop u_pll_ch1` 模块输出. 任何对 PLL ch1 实例化的注释/删除,
  都会让 USB 数据通路无声失效.
- **修复**:
  把 USB 数据触发信号改为同步频率的 `dc_valid_x_ch3_21` (来自
  `lockin_psd u_psd_ch3_21`), 这条路径不依赖 PLL.
  同时新增 3 条上位机命令 `FRQ21/FRQ12/FRQ11`, 让上位机能手动下发
  通道 3 三路开环锁相的参考频率 (原本是固定常数, 不可调).
  **后续 (2026-05-12)**: PLL 恢复后触发改回 `dc_valid_x_ch1`;
  **2026-06-11**: FT245/`usb_commend` 迁 `clk_65M`, 同域直连, 消除 CDC 漏采。
- **状态**: ✅ 已解决
- **关联文件**:
  - `project_1.srcs/sources_1/new/lock_in_amp.v` 行 ~451 (m_axis_data_tvalid_fir_x 重新接线)
  - `project_1.srcs/sources_1/new/lock_in_amp.v` 行 265/285/305 (三路 ref_freq 改为 wire)
  - `project_1.srcs/sources_1/new/usb_commend.v` (新增 FRQ21/12/11 三条命令)
  - `lockin_gui/main_window.py` (新增 GUI 输入框)
  - `lockin_gui/device.py` (MockDevice 默认值)
  - `docs/UART_Protocol.md` (新增协议条目)
- **备注**:
  - **走错过的方向不要再走**: 一开始怀疑 GUI 解析格式不一致 / 串口波特率不对,
    其实命令通道完全正常, 只是数据触发信号悬空.
  - **未来教训**: 凡是注释/删除 RTL 中的子模块, 必须 grep 所有引用,
    否则会留下"悬空 wire"陷阱. Vivado 综合不会报错, 但运行时静默失效.
    建议综合后查看 Warning 里的 `[Synth 8-3331] design has unconnected ports`
    类似条目.
  - **设计建议**: USB / UDP 数据帧的触发信号不应耦合到具体子模块的内部信号,
    应该由 lock_in_amp.v 顶层维护一个稳定的 "frame_tick" 信号 (例如
    `dc_valid_x_ch3_21` 或基于固定时钟分频的脉冲), 这样任何子模块的增删
    都不会影响数据回传.
  - **相关 issue**: 已知 USB 数据路径无 CDC FIFO (UDP 路径有),
    在 PLL 闭环模式下会引入相位抖动. 待 USB 重要性下降后再修.

---

## 2026-05-11 · 通道 3 ADC 采样波形出现规律性"锯齿"

- **发现日期**: 2026-05-11
- **关联模块/层**: PCB / IO 引脚分配 (xdc)
- **现象**:
  通道 3 (`adc_ch3`) 采集到的正弦波形上叠加规律性、周期性的"锯齿状"小幅
  抖动 (非随机噪声). 通道 1、通道 2 用同一份 `ad_wave_rec.v` 代码,
  波形完全干净, 只有 ch3/ch4 (第二块 AD9248) 有锯齿.
- **排查过程**:
  1. 怀疑 `ad_wave_rec.v` 的 A/B 通道采样边沿配错 (A 用 posedge, B 用 negedge).
     → 因 ch1/2 用同一份代码无锯齿, 排除.
  2. 怀疑 `adc_clk_2` 引脚 (AA18) 不是 Clock-Capable (CC) 引脚, 时钟分布偏斜大.
     → Tcl 查 `IS_CLK_CAPABLE`: G16 (ch1/2 clk) = 0,  AA18 (ch3/4 clk) = 1.
     → ch3 反而用了 CC 引脚, 假设被推翻.
  3. 对比两块 ADC 的引脚布局, 发现 ch3/4 的 14 位数据线分散在 AB16~V22
     (跨 16~22 行, PCB 走线长度差异大), ch1/2 数据线集中在 A16~F16.
- **根因**:
  **PCB 走线长度不等长 + 散布过大** —— 14 位 ADC 数据线分散在不同行,
  走线长度差异让某些位的 setup/hold 余量被拉到边缘, 在 65 MHz 采样下时序紊乱,
  造成部分位被错误采样, 表现为周期性锯齿.
- **修复**:
  把 ADC2 (ch3/4) 全部引脚重新分配到右上角同一小片相邻 IO 上 (V13~AB17),
  数据线 + 时钟 + 控制线物理位置集中, 走线短且自然等长.
  见 `project_1.srcs/constrs_1/new/pin.xdc` 行 95~112.
  旧引脚分配保留为注释 (行 75~92) 作历史参考.
- **状态**: ✅ 已解决
- **关联文件**:
  - `project_1.srcs/constrs_1/new/pin.xdc` (引脚约束)
  - `project_1.srcs/sources_1/new/ad_wave_rec.v` (RTL, 未改动)
- **备注**:
  - **走错过的方向不要再走**: 别再怀疑 `ad_wave_rec.v` 的采样边沿 / CC 引脚.
  - **未来教训**: 高速并行总线 (ADC 14 位数据 + 时钟) 的引脚分配必须**物理相邻 + 走线等长**.
    优先选板上同一 IO bank、连续行/列的 IO; 别为了"凑齐路数"把数据线散到几个区域.
  - **加强方案 (尚未启用)**: 如果以后波形再次飘抖, 可以在 xdc 里加
    `set_property IOB TRUE [get_ports {adc_data_2[*]}]` 强制 IOB 寄存器 packing,
    进一步收紧时序余量.
  - **类似问题预防**: 以后增加新的并行总线 IP 时, 第一步就先确认引脚都在同一区域.

---

<!-- ↑↑↑ 新问题请加在这条线之上, 按时间倒序 ↑↑↑ -->
