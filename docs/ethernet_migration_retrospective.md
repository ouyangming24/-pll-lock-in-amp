# 以太网 UDP 迁移 — 调试复盘

> 本文档是 [`ethernet_migration_plan.md`](./ethernet_migration_plan.md) 的**事后总结**。规划文档讲"打算怎么做"，本文档讲"实际怎么做的、踩了哪些坑、怎么解决的"。
>
> - **任务期间**: 2026-05-06 ~ 2026-05-08
> - **目标**: 将锁相数据上行通道从 FT245 USB FIFO (~7 Mbps) 迁移到千兆以太网 UDP (~970 Mbps)
> - **结果**: ✅ 成功调通，GUI 已集成 UDP 模式 (`python main.py --udp`)
> - **当前传输速率**: 3.6 kbps (受 FPGA 内部 `dc_valid` 节流，非链路限制)
> - **理论上限**: ~970 Mbps (千兆 UDP 实测约值)

---

## 一、最终架构

### 1. 数据通路

```
┌──────────────────── FPGA (xc7z020) ────────────────────┐  ┌────── PC ──────┐
│                                                         │  │                │
│  [65 MHz 域]                  [125 MHz 域]              │  │                │
│                                                         │  │                │
│  锁相核心 ─► x_y_fir_packed ─► XPM_FIFO_ASYNC ─►        │  │                │
│  (640 bit)   dc_valid_x_ch1   (CDC 缓冲)               │  │                │
│                                  │                      │  │                │
│                                  ▼                      │  │                │
│                            udp_lockin_tx                │  │                │
│                            (生成 UDP 头)                │  │                │
│                                  │                      │  │                │
│                                  ▼ AXI-Stream           │  │                │
│                            udp_complete                 │  │                │
│                            (UDP/IP/ARP)                 │  │                │
│                                  │                      │  │                │
│                                  ▼ AXI-Stream           │  │                │
│                       eth_mac_1g_rgmii_fifo             │  │                │
│                       (alexforencich)                   │  │                │
│                                  │                      │  │                │
│                                  ▼                      │  │                │
│                  RGMII (TXC/TXD[3:0]/TXCTL,            │  │                │
│                          RXC/RXD[3:0]/RXCTL)            │  │                │
│                            ↑ IDELAYE2 ×5                │  │                │
│                                  │                      │  │                │
└──────────────────────────────────┼──────────────────────┘  │                │
                                   ▼                          │                │
                              [RTL8211E PHY]                  │                │
                                   │                          │                │
                                   ▼ MDI 双绞线               │                │
                              ──────────────────► 网线 ──────►│ host_udp.py    │
                                                              │ (UDP socket)   │
                                                              │ 或 lockin_gui  │
                                                              │ (UdpLockinDevice)│
                                                              └────────────────┘

   命令通道 (FT245 USB 串口) ←─── 保留, 仅用于发送 SET/FREQ/KP/KI 等指令
```

### 2. 时钟域

| 时钟 | 频率 | 来源 | 用途 |
|---|---|---|---|
| `sys_clk` | 50 MHz | 板载 PL 输入 | 系统主时钟 |
| `clk_65M` | 65 MHz | `clk_wiz_0` 锁相输出 | 锁相核心 + ADC 采样域 |
| `clk125` | 125 MHz | `clk_wiz_eth` 输出 1 | RGMII 数据时钟 (0°) |
| `clk125_90` | 125 MHz | `clk_wiz_eth` 输出 2 | RGMII TX 时钟 (90°相移, 备用) |
| `clk200` | 200 MHz | `clk_wiz_eth` 输出 3 | IDELAYCTRL 参考时钟 |

> ⚠ `clk_wiz_eth` 多增加的 200 MHz 输出是为了驱动 `IDELAYCTRL`，这一步是用 Tcl 脚本 `tools/update_clk_wiz_eth_for_idelay.tcl` 完成的。

### 3. IP / 端口配置

| 项 | 值 | 说明 |
|---|---|---|
| FPGA MAC | `02:00:00:00:00:01` | 自定义本地管理 MAC |
| FPGA IP | `192.168.99.10` | **不能用 192.168.1.x**（见问题 #14） |
| FPGA UDP src port | 1234 | 数据包源端口 |
| FPGA UDP dst port | 7777 | 数据包目的端口 |
| PC IP | `192.168.99.100` | 网卡"以太网 5"静态分配 |
| PC 监听端口 | 7777 | `host_udp.py` / `UdpLockinDevice` |
| 子网掩码 | `255.255.255.0` | /24 |
| 网关 | `192.168.99.1` | 实际不存在，FPGA 仅在跨网段时用 |

### 4. 关键文件清单

#### 新增 (RTL)

| 文件 | 行数 | 作用 |
|---|---|---|
| `project_1.srcs/sources_1/new/eth_lockin_top.v` | ~830 | 以太网顶层：CDC + UDP 协议栈 + MAC + IDELAY 扫描器 |
| `project_1.srcs/sources_1/new/udp_lockin_tx.v` | ~140 | 把 640-bit 锁相帧转成 80 字节 AXI-Stream + UDP 头 |
| `project_1.srcs/sources_1/new/eth_phy_init.v` | ~80 | RTL8211E 上电复位时序 |
| `project_1.srcs/sources_1/new/altera_stubs.v` | ~70 | Altera 原语空壳，消除 Vivado 红问号 (XILINX 目标下不参与综合) |
| `project_1.srcs/constrs_1/new/eth_pins.xdc` | ~80 | RGMII 引脚 + I/O 标准 + 输入/输出延迟约束 |

#### 新增 (Host)

| 文件 | 作用 |
|---|---|
| `tools/host_udp.py` | 命令行 UDP 接收器（验证用），解析 80 字节帧、统计 FPS、可选 CSV 落盘 |
| `lockin_gui/device.py` 新类 `UdpLockinDevice` | GUI 后端：命令走 FT245 串口，数据走 UDP socket |

#### 修改 (RTL)

| 文件 | 改动 |
|---|---|
| `project_1.srcs/sources_1/new/lock_in_amp.v` | 加 RGMII 引脚 + LED 调试输出，例化 `eth_lockin_top` |

#### 修改 (Host / Doc)

| 文件 | 改动 |
|---|---|
| `lockin_gui/main.py` | 加 `--udp` 启动参数 |
| `lockin_gui/main_window.py` | 接受 `udp_mode`，根据模式选择 `LockinDevice` / `UdpLockinDevice` / `MockDevice`，状态栏显示当前模式 |
| `lockin_gui/README.md` | 文档化三种模式 |
| `tools/update_clk_wiz_eth_for_idelay.tcl` | Tcl 脚本：重配 `clk_wiz_eth` IP 加 200 MHz 输出 |
| `.gitignore` | 加 `third_party/` |

#### 第三方库 (未改一行源码，仅添加引用)

`third_party/verilog-ethernet/` 下的 41 个 `.v` 文件，从 [alexforencich/verilog-ethernet](https://github.com/alexforencich/verilog-ethernet) 直接 clone。

---

## 二、踩坑 & 解决方案 完整时间轴

按发现顺序排列，每个坑都给出**现象 → 排查 → 根因 → 解法**，方便日后复用。

### Phase A: 工具链 / 工程组织 (5/6 上午)

#### 坑 #1：`project_1.srcs/sources_1/imports` 文件夹不存在

- **现象**: 我最初让你把第三方库放进 `imports/`，但用户工程根本没这个目录
- **根因**: `imports/` 是 Vivado 早期工程导入的旧约定；新工程不会自动创建
- **解法**: 改用 `third_party/verilog-ethernet/`，放在工程根目录、不在 Vivado 受控目录里，`.gitignore` 屏蔽避免污染仓库

#### 坑 #2：`[Vivado 12-4029]` 文件路径解析失败

- **现象**: Tcl 脚本里用 `pwd`，结果解析到 `C:/Users/Lenovo/AppData/...` (Vivado 安装目录)
- **根因**: Tcl 启动时 `pwd` 是 Vivado 进程的工作目录，**不是工程目录**
- **解法**: 改用 `set proj_root [get_property DIRECTORY [current_project]]`

#### 坑 #3：第三方库文件没加全（Synth 8-448）

- **现象**: 综合报"找不到 `eth_arb_mux` / `mac_ctrl_rx` / `axis_adapter` / ..."等模块
- **根因**: `verilog-ethernet` 模块依赖图很复杂，单纯加 `udp_complete.v` + `eth_mac_1g_rgmii_fifo.v` 远远不够
- **解法**: 用 Tcl 一次性把 `rtl/*.v` + `lib/axis/rtl/*.v` 全部 `add_files` 进来，41 个文件

#### 坑 #4：`altddio_in` / `altddio_out` 红问号

- **现象**: Vivado 层级视图 (Hierarchy) 里 `altera_stubs.v` 引用 Altera 原语，红色问号
- **根因**: `verilog-ethernet` 用 `generate if (TARGET == "ALTERA")` 切换原语，Vivado 静态扫源码时没看见 generate 选择，把 Altera 那一支也算上了
- **解法**: 提供空 stub `altera_stubs.v`，仅消除视觉警告，**不会进综合**（因为 `generate if (TARGET == "XILINX")` 排除了它）

#### 坑 #5：`ifg_delay` 端口不存在 (Synth 8-448)

- **现象**: 综合报 `eth_mac_1g_rgmii_fifo` 没有名为 `ifg_delay` 的端口
- **根因**: `verilog-ethernet` 库升级后端口重命名了
- **解法**: 修改 `eth_lockin_top.v` 的例化：
  - `ifg_delay` → `cfg_ifg`
  - 新增 `cfg_tx_enable`, `cfg_rx_enable`, `tx_axis_tkeep`, `rx_axis_tkeep`

#### 坑 #6：Tcl `[+]` 语法错误

- **现象**: 运行 `update_clk_wiz_eth_for_idelay.tcl` 时报 `invalid command name "+"`
- **根因**: Tcl 中 `[ ]` 是命令替换语法，`puts "[+] info..."` 被解析成"调用一个叫 `+` 的命令"
- **解法**: 全部换成 `==>` 这种纯文本前缀

---

### Phase B: 物理层 / RGMII 时序 (5/6 下午 ~ 5/7)

#### 坑 #7：链路 Up，但 PC `ping` 不通，Wireshark 看不到 ARP 应答

- **现象**: 板上 PHY LINK 灯亮，PC 网卡也是"已连接 1 Gbps"，但 ping 100% 丢包
- **第一轮假设**: RX 时序问题 —— RTL8211E 默认输出 RGMII edge-aligned，需要 FPGA 在 RX 路径上加延迟
- **行动**:
  1. 在 `eth_lockin_top.v` 里加 `IDELAYCTRL` + 5 个 `IDELAYE2`（4 个数据 + 1 个 control）
  2. 给 `clk_wiz_eth` 加 200 MHz 输出（IDELAYCTRL 必需）
  3. 用 Tcl 脚本 `tools/update_clk_wiz_eth_for_idelay.tcl` 完成 IP 重配
- **结果**: 仍然 ping 不通

#### 坑 #8：固定 tap 值碰运气，永远找不到正确值

- **现象**: 试了 `RX_IDELAY_TAP = 0, 8, 16, 24, 30` 都不通
- **根因**: 78 ps × 32 = 2.5 ns 范围里只有约 ±200 ps 的窗口能正确采样，盲试效率太低
- **解法**: ★ **写了一个 IDELAY 自动扫描状态机** ★
  - 上电后从 `tap = 0` 开始，每个 tap 停留 1.5 秒
  - 检测条件：`rx_fifo_good_frame` 脉冲（MAC 校验通过的帧）累计 ≥ 3 次 → 锁定该 tap
  - 32 个 tap 全部走一遍仍未锁定 → 标记 `idelay_scan_failed`
  - 输出 `idelay_scan_locked` / `idelay_scan_failed` / `idelay_scan_tap_now` 用于 LED 指示

#### 坑 #9：扫描器**误锁**（用 `rx_axis_tvalid` 而非 `rx_fifo_good_frame`）

- **现象**: LED 指示 IDELAY 已锁定，但 ping 仍然不通
- **根因**: 起初扫描器用 `rx_axis_tvalid` 当判据。MAC 看到 SFD 后就拉高 valid，**即使后面 CRC 错了 valid 也维持一段时间**。噪声很容易触发，导致 tap=0 就被误锁
- **解法**:
  - 把判据换成 `rx_fifo_good_frame`（MAC 校验完整通过才发的脉冲）
  - 把 dwell 时间从 150 ms 拉长到 1.5 s
  - 把锁定门槛从"任意一帧"提到"≥ 3 帧"

#### 坑 #10：诊断手段不够，看不到底是哪一层卡住

- **现象**: 只有"ping 不通"这一个症状，无法定位是 RX 还是 TX，是物理层还是协议层
- **解法**: 在 `eth_lockin_top.v` 里加了 5 层诊断输出，引到 `pl_led1`/`pl_led2` 上：

  | 信号 | 物理含义 |
  |---|---|
  | `eth_link_up` | PHY 链接是否建立 |
  | `rxctl_pin_activity` | RX_CTL 引脚有没有跳变 (纯物理层) |
  | `rxd_per_bit_active` | 4 位数据线分别有没有跳变 |
  | `rx_eth_hdr_activity` | `eth_axis_rx` 解析出 ARP 帧头 (协议层 RX) |
  | `tx_axis_activity` | `arp_tx` 在产生 ARP 响应 (协议层 TX) |
  | `idelay_scan_locked/failed/tap_now` | IDELAY 扫描器状态 |

  ```verilog
  // 最终的 LED 真值表 (lock_in_amp.v)
  // IDELAY 锁定后:
  //   LED1 闪 + LED2 闪 → ARP 协议层 OK, 100% 是 PHY 物理层 TX 问题
  //   LED1 闪 + LED2 灭 → ARP 没回, LOCAL_IP 配置或 ARP 模块 bug
  //   LED1 灭 + LED2 灭 → 收到的不是 ARP (PC 路由问题)
  ```

#### 坑 #11：TX 物理层 — `USE_CLK90` 参数错误

- **现象**: 内部 LED 指示 `tx_axis_activity` 闪烁（FPGA 在产生 ARP 响应），但 Wireshark **完全看不到 FPGA 出来的包**
- **根因**: `eth_mac_1g_rgmii_fifo` 有个 `USE_CLK90` 参数：
  - `"TRUE"`：TX 数据用 0° 时钟，TXC 用 90° 时钟（数据中心对齐 TXC 上升沿）
  - `"FALSE"`：TX 数据和 TXC 都用 0° 时钟（边沿对齐）
  - RTL8211E 默认开启了内部 TXDLY，所以**需要边沿对齐**，不是中心对齐
- **解法**: 把 `eth_lockin_top.v` 的 `eth_mac_1g_rgmii_fifo` 参数 `.USE_CLK90("TRUE")` 改成 `.USE_CLK90("FALSE")`
- **结果**: ✅ 立刻通了，PC 上 `arp -a` 看到 FPGA 的 MAC

---

### Phase C: 网络层 / PC 配置 (5/6 ~ 5/7 中间穿插)

#### 坑 #12：PC 网卡"媒体已断开连接"

- **现象**: `ipconfig` 显示"以太网 5: 媒体已断开连接"
- **根因**: 物理连接问题（网线没插好 / PHY 没起来 / 烧的 bit 不带以太网逻辑）
- **解法**: 重新烧录、检查网线、确认 PHY LINK 灯亮

#### 坑 #13：`ping 192.168.1.10.` (尾巴有个点)

- **现象**: 用户在 ping 命令后多敲了个点，`ping` 把它当域名查 DNS，被代理软件劫持，看到奇怪的响应
- **根因**: Windows `ping` 对结尾的 `.` 处理是"绝对域名"，会触发 DNS 解析
- **解法**: 去掉点

#### 坑 #14：代理软件 (Meta 适配器) 拦截 UDP

- **现象**: `ipconfig` 看到莫名其妙的"未知适配器 Meta: 198.18.0.1"
- **根因**: 用户的代理软件创建了虚拟网卡，把所有 UDP 流量重定向走代理隧道
- **解法**: 完全退出代理软件，确认 `ipconfig` 不再有 Meta 适配器

#### 坑 #15：★ IP 子网冲突 ★（隐藏最深的坑）

- **现象**: ping 之后 LED1 闪一下（说明 ARP 请求到了 FPGA），LED2 也闪一下（说明 FPGA 在产生 ARP 响应），但**之后 ping 都收不到回应，Wireshark 也再没流量**
- **第一轮排查**: 怀疑 IDELAY 锁不稳，把扫描器改严
- **第二轮排查**: 怀疑 PHY TX 物理层（最后证实了）
- **隐藏的根因**: PC 上**有两个网卡都在 192.168.1.0/24 子网**：
  - "以太网 5"（接 FPGA）：`192.168.1.100`
  - 家用路由器 WiFi/有线：`192.168.1.x`，网关 `192.168.1.1`
  - 操作系统看到 `192.168.1.10` 时不知道走哪个接口，ARP 请求可能走错路
- **解法**: ★ **把 FPGA 的整个网段改到 192.168.99.0/24** ★
  - `lock_in_amp.v` 里 `LOCAL_IP / DEST_IP / GATEWAY_IP` 全部 `192.168.1.x` → `192.168.99.x`
  - PC "以太网 5" 重新配静态 IP `192.168.99.100`
  - `host_udp.py` 默认参数同步更新

> **教训**: 在公司/家里用以太网调 FPGA，**永远要避开 192.168.1.x 这个最常见的家用路由器子网**。99/77/88/123 这种冷门段更安全。

---

### Phase D: 上位机集成 (5/8)

#### 坑 #16：`udp_complete` 不响应 ICMP

- **现象**: ARP 通了（`arp -a` 看到 FPGA），但 `ping` 还是返回"请求超时"
- **根因**: `udp_complete` 模块只实现 UDP/IP/ARP 协议，**完全没有 ICMP echo reply**。`ping` 永远不可能通
- **解法**: 不要用 `ping` 做连通性测试。改用：
  - `arp -a | findstr 192.168.99.10` 查 MAC 是否在缓存里 (这才是真实判据)
  - 直接跑 `host_udp.py`，能收到数据就说明 UDP 双向通

#### 坑 #17：GUI 集成时的命令通道选择

- **现象**: UDP 模式下命令也走 UDP？还是继续走串口？
- **决策**: 命令继续走 FT245 串口
  - 命令量很小（几个字节），不需要 UDP 带宽
  - 命令需要可靠传输，UDP 不可靠（虽然 LAN 一般不丢）
  - 减少 FPGA 端 UDP RX 的逻辑（只做单向 TX）
- **实现**:
  - 新建 `UdpLockinDevice` 类（`device.py`），同时持有：
    - 一个 `serial.Serial` 对象（命令）
    - 一个 `socket.socket` 对象（数据）
  - 信号接口与 `LockinDevice` 完全一致，主窗口透明切换

#### 坑 #18：异步信号 IDELAY 扫描期间用户不知所措

- **现象**: 烧完 bit、连好网线，但 ~50 秒里 GUI 一直没数据
- **根因**: IDELAY 扫描器要从 tap=0 走到 tap=N（N≤32），每个 tap 1.5 s
- **解法**: 在 `lockin_gui/README.md` 和 `tools/host_udp.py` 提示文字里写明"上电后等 ~50 秒，看 PL_LED1 由灭转闪即代表锁定成功"

---

## 三、最终验证清单

### 1. 物理层

- [x] PHY LINK 灯：常亮（千兆链接）
- [x] PHY ACT 灯：闪烁（有数据通过）
- [x] `pl_led1`：IDELAY 锁定后开始闪烁（RX 协议层活动）
- [x] `pl_led2`：IDELAY 锁定后开始闪烁（TX 协议层活动）

### 2. 网络层

```cmd
> arp -a | findstr 192.168.99.10
  192.168.99.10         02-00-00-00-00-01     动态
```
✅ FPGA 的 MAC 在 PC ARP 缓存里 → 网络层双向通

> 注：`ping 192.168.99.10` **会显示"请求超时"，这是预期**，因为 `udp_complete` 不实现 ICMP。

### 3. 应用层

```bash
> python tools/host_udp.py
[INFO] listening on 0.0.0.0:7777, expecting frames from 192.168.99.10
[2026-05-08 10:23:01] frame #1234 fps=5.7 dropped=0 ch1_lock=1 f1=53497.812
[2026-05-08 10:23:02] frame #1240 fps=5.7 dropped=0 ch1_lock=1 f1=53497.812
...
```
✅ 命令行收数据正常

### 4. GUI

```bash
> python lockin_gui\main.py --udp
```
✅ 状态栏显示蓝色"以太网 UDP 模式"
✅ F1 锁定指示亮，频率显示稳定
✅ 4 路波形流畅刷新
✅ 串口命令（FRQ2、KP、KI 等）正常下发

---

## 四、关键工程经验

### 1. 千兆 RGMII 的"接力顺序"——RX 比 TX 难调

| 方向 | 谁产生时钟 | 谁产生数据 | 时序对齐 |
|---|---|---|---|
| **TX** | FPGA | FPGA | FPGA 自己内部对齐，PHY 通常默认 RXDLY 已开 |
| **RX** | PHY | PHY | 取决于 PHY 是否开 TXDLY，**FPGA 要么靠 IDELAY 调，要么靠 PHY 内部加 2ns** |

**经验**：
- 不要试图通过寄存器配置去开 PHY 的 TXDLY/RXDLY，太繁琐且易错
- 直接在 FPGA 端用 `IDELAYE2` 调（即使浪费几片硅，确定性高）
- ★ 必备：**自动扫描器** ★，省去手工试 32 个 tap 的工作量

### 2. 网络调试三件套：LED + Wireshark + arp

| 工具 | 看什么 | 解决什么 |
|---|---|---|
| **板上 LED** | RX/TX 协议层是否活动 | FPGA 内部状态 |
| **Wireshark** | 物理层数据是否真出 PHY | TX 物理时序问题 |
| **arp -a** | 网络层是否双向通 | IP 配置 / 路由问题 |

**判读组合**:
- LED2 闪 + Wireshark 没出包 → TX 物理层（USE_CLK90 / 输出延迟约束）
- Wireshark 出包 + arp -a 没缓存 → IP 配置错或子网冲突
- arp -a 有缓存 + UDP 收不到 → 防火墙 / 端口被占

### 3. 不要相信 `ping`

`ping` 依赖 ICMP，但纯硬件 UDP/IP 协议栈通常不实现 ICMP。**真实判据是 `arp -a` + 实际 UDP 流量**。

### 4. 子网选择的潜规则

```
✗ 192.168.1.x  ← 99% 的家用路由器在用，必冲突
✗ 192.168.0.x  ← 也很常见
✓ 192.168.99.x ← 安全
✓ 192.168.123.x ← 安全
✓ 10.0.X.x     ← 通常安全 (除非公司用)
```

---

## 五、性能数据

### 当前运行参数

| 项 | 值 | 说明 |
|---|---|---|
| 帧大小 | 80 bytes | 4-byte sync + 22 个 int32 + flags |
| 帧速率 | ~5.7 fps | 由 `dc_valid_x_ch1` 节流（CIC 抽取 + IIR 平滑） |
| 实际数据速率 | ~3.6 kbps | 80 × 5.7 × 8 |
| 链路理论上限 | ~970 Mbps | 千兆 UDP 实测约值 |
| 链路利用率 | **0.0004 %** | 余量极大 |

### 与原 FT245 USB 对比

| 指标 | FT245 USB | 千兆以太网 UDP | 倍数 |
|---|---|---|---|
| 物理层带宽 | ~7 Mbps | ~1000 Mbps | ×140 |
| 当前实际帧率 | ~5.7 fps（一样） | ~5.7 fps | ×1 |
| 距离限制 | <5 m USB 线 | 100 m 网线 | ×20 |
| 多机分发 | 只能 1 对 1 | UDP 组播 / 多 PC | ✓ |

> 当前虽然没用满带宽，但**链路准备好了**。后续如果加：
> - 多通道 ADC 原始数据回传
> - 实时 X/Y 高速流（不经 IIR 节流）
> - PSD 频谱在线计算结果回传
>
> 都不再有带宽瓶颈。

---

## 六、未来工作建议

| 优先级 | 任务 | 预计工作量 |
|---|---|---|
| ★★ | 把 `RX_IDELAY_AUTO` 默认改为 0，固定到收敛后的 tap 值 | 30 min（重综合一次） |
| ★★ | 把命令通道也搬到 UDP（FPGA 加 `udp_rx` + 简单字节流解析），彻底拔掉 USB | 1 天 |
| ★ | 给 `udp_complete` 加最小 ICMP echo reply，让 `ping` 能通（纯调试便利） | 半天 |
| ★ | 把 `dc_valid` 节流改为可配置（让 GUI 能切换"低速诊断" vs "高速采集"） | 半天 |
| ☆ | 用 Wireshark dissector 写一个针对本协议的 lua 脚本，方便抓包查看 | 1 天 |

---

## 附录：相关文档

- [`ethernet_migration_plan.md`](./ethernet_migration_plan.md) — 迁移规划（事前）
- [`Interface_Spec_for_SW.md`](./Interface_Spec_for_SW.md) — 接口规范（80 字节帧格式）
- [`UART_Protocol.md`](./UART_Protocol.md) — 命令协议（FT245 串口）
- [`pll_controller_flowchart.md`](./pll_controller_flowchart.md) — PLL 控制器流程
- [`../lockin_gui/README.md`](../lockin_gui/README.md) — GUI 三种模式说明
- [`../tools/host_udp.py`](../tools/host_udp.py) — 命令行 UDP 接收器
