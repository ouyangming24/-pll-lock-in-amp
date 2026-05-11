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
- **状态**: ⚠ 部分完成 — 命令路径就绪, mux 路径就绪, 但当前强制手动 (PLL 恢复后激活).
- **关联文件**:
  - `project_1.srcs/sources_1/new/usb_commend.v` (新增 REFMODE 命令)
  - `project_1.srcs/sources_1/new/lock_in_amp.v` (新增 ref_freq mux, 强制手动)
  - `docs/UART_Protocol.md` (新增 6.3.8c)
- **PLL 恢复后激活清单**:
  - [ ] 取消 `pll_loop u_pll_ch1` / `u_pll_ch2` 实例化注释 (lock_in_amp.v 行 ~138/~187)
  - [ ] 删除/注释 lock_in_amp.v 中"PLL 注释期间"3 行强制手动 assign
  - [ ] 取消下方"PLL 恢复后启用"3 行 mux assign 注释
  - [ ] 把 USB 数据触发信号从 `dc_valid_x_ch3_21` 改回 `dc_valid_x_ch1`
  - [ ] 重新综合 + 烧写
  - [ ] 上位机发 `REFMODE:1` 验证硬件自动跟随

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
