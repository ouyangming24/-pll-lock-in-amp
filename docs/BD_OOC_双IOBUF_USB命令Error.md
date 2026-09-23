# BD OOC 双 IOBUF 导致 USB 命令全 Error

**日期**: 2026-09-23  
**状态**: 已解决（JTAG 烧 `design_1_wrapper.bit` 后命令恢复 Success）  
**器件**: XC7Z020-CLG484 / Vivado 2025.1  
**关联**: 固化（Zynq PS + PL `lock_in_amp`）后 FT245 串口指令失败

---

## 1. 现象

| 烧录对象 | 结果 |
|----------|------|
| 顶层 `lock_in_amp` 的 bitstream | 软件能连，XCOM 发 `KP:1` 等指令正常，回 **Command Success!** |
| Block Design 顶层 `design_1_wrapper` 的 bitstream | 能回包，但一律 **Command Error!**；界面偶发显示 `CCommand Error!`；GUI 无法正常连接、无数据 |

补充说明：

- `CCommand Error!` 不是多收了一个 `C`，而是应答 `Command Error!\r\n` 的显示/粘包。
- 有 Error 回包说明 PL 在跑、FT245 **写方向**大致可用，问题在 **读方向字节不对**，解析器认不出 `KP:` / `XYOUT` 等命令。
- 独立 PL 工程与 wrapper 用的是同一份 `usb_commend.v` / `ft245_rx.v`，协议本身没有坏。

---

## 2. 排查过程（走过的弯路）

当时容易误判成：SD/`BOOT.bin`、波特率、换行、以太网约束、PS `FCLK`、未约束的 `pl_led` 抢脚等。

这些方向后来都被对比实验排除或降级：

1. **不是协议/上位机**：同一套 XCOM/`--serial`，独立 `lock_in_amp.bit` 正常。
2. **不是单纯“没加载 PL”**：wrapper 能回 Error，说明 `usb_commend` 在跑。
3. **不是 FT245 管脚写错**：`pin_solidify.xdc` 的 `ft_*` 与 `pin.xdc` 一一对应（仅多 `_0`）。
4. **不是 FCLK 频率**：后来已把 `sys_clk`/`sys_rst_n` 改回板载晶振 M19 / 复位 J20，与独立工程相同，问题仍在。
5. **删以太网、补 LED 约束**不能单独治好；甚至一度出现“连 Error 都没了”（综合/实现状态混乱）。

**一锤定音的对比**：只换顶层（`lock_in_amp` vs `design_1_wrapper`），RTL 命令机相同 → 问题在 **BD 封装/综合方式**，不在命令解析代码。

---

## 3. 根因

`lock_in_amp` 内部对 FT245 数据总线做了三态：

```verilog
assign ft_d    = ft_d_oe ? ft_d_tx : 8'bz;
assign ft_d_in = ft_d;
```

`ft_d` 是 `inout [7:0]`。

| 顶层 | 综合方式 | IOBUF 层数 |
|------|----------|------------|
| `lock_in_amp` | 直接当工程顶层 | 只在封装管脚推断 **一层** IOBUF → 读写正常 |
| `design_1_wrapper` | `lock_in_amp` 作为 BD **module_ref**，默认 `synth_flow_mode = Hierarchical`（OOC） | OOC 把 `lock_in_amp` 当成“顶层”，在 IP 边界先推断 IOBUF；真正的 `ft_d_0` 在 wrapper 再推断一层 |

**双 IOBUF** 的典型表现：

- 写（FPGA → FT245）：还能出去，所以能看到 `Command Error!`
- 读（FT245 → FPGA）：读到的是内部高阻/旧值/乱码，命令对不上，一律走 Error 分支

BD / XCI 上对应的默认设置：

- `design_1.bd`：`synth_flow_mode = Hierarchical`
- `design_1_lock_in_amp_0_0.xci`：`SYNTHESISFLOW = OOC_HIERARCHICAL`

---

## 4. 修复

核心：**禁止把带 `inout` 三态的 `lock_in_amp` 按 OOC 单独综合**，改为随顶层 **Global** 综合，让 IOBUF 只出现在封装管脚上。

### 4.1 工程里已改的文件

| 文件 | 改动 |
|------|------|
| `project_1.srcs/sources_1/bd/design_1/design_1.bd` | `synth_flow_mode`：`Hierarchical` → **`None`** |
| `fix_bd_ooc_ft245.tcl` | 打开工程后一键设置 `synth_checkpoint_mode None` |
| `project_1.srcs/constrs_1/new/pin_solidify.xdc` | 去掉已不存在的 `pl_led*_0` 约束（当时 wrapper 已无 LED 口） |

**没有改** `usb_commend.v` 的命令协议，也没有改 FT245 管脚表。独立顶层 `lock_in_amp` 仍可按原方式出 bit。

### 4.2 Vivado 必须再做的步骤（只改文件不够）

旧的 OOC `.dcp` 若还在，会继续编出坏 bit。

1. 工程已打开时，Tcl Console：

```tcl
source E:/company/Aunion/Lock_In_Amp/FPGA-2/git_pll/fix_bd_ooc_ft245.tcl
```

成功标志：

```text
design_1.bd synth_checkpoint_mode = None
```

2. 若出现：

```text
ERROR: [Common 17-107] Cannot change read-only property 'generate_synth_checkpoint'
```

**可忽略**。`generate_synth_checkpoint` 对 module_ref 只读；真正起作用的是 BD 的 `synth_checkpoint_mode = None`。

3. 打开 `design_1.bd` → **Generate Output Products** → 选 **Global**（不要 Hierarchical）→ Generate  
4. **Reset Synthesis / Implementation**，重新生成 `design_1_wrapper.bit`  
5. **先 JTAG 烧 wrapper.bit** 验证，再 Export XSA / 更新 Vitis / 重做 `BOOT.BIN`

综合时不应再把 `design_1_lock_in_amp_0_0` 当成黑盒 OOC 拼进去。

---

## 5. 验证结果

JTAG 烧按 Global 重新实现的 `design_1_wrapper.bit` 后：

- 串口发送 `KP:1`（以及其它合法命令）→ **Command Success!**
- 软件可以正常连接（此前 Error 导致 GUI 无法进入正常数据流）

---

## 6. 以后注意

1. **带 `inout` / `assign x = oe ? d : 1'bz` 的模块，不要放进 BD 做 OOC Hierarchical 综合。**  
   要么 Global，要么把总线拆成 `i / o / t`，只在真正的顶层做一层 IOBUF。
2. 固化流程建议固定为：顶层 `design_1_wrapper`；只启用 `pin_solidify.xdc`；禁用 `pin.xdc` / `eth_pins.xdc` / `eht_pinx_solidify.xdc`。
3. 出问题先做对比：同一份 RTL，独立 `lock_in_amp.bit` vs wrapper.bit。前者好、后者坏，优先查 BD/OOC/inout，而不是先改协议。
4. 换过 BD 综合模式或 XSA 后，必须 **Reset Runs + 重新 Generate Output Products**，不要沿用旧 OOC checkpoint。
5. SD 启动另需确认 `BOOT.BIN` 里的 bit 就是这份验证过的 wrapper.bit；那是镜像问题，与本次双 IOBUF 不是同一层。

---

## 7. 相关路径

- RTL 三态：`project_1.srcs/sources_1/new/lock_in_amp.v`
- 命令解析：`project_1.srcs/sources_1/new/usb_commend.v`
- FT245 读：`project_1.srcs/sources_1/new/ft245_rx.v`
- Wrapper 约束：`project_1.srcs/constrs_1/new/pin_solidify.xdc`
- BD：`project_1.srcs/sources_1/bd/design_1/design_1.bd`
- 一键脚本：`fix_bd_ooc_ft245.tcl`
