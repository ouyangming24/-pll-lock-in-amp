# 以太网 (UDP) 上行迁移指南 — LXB-ZYNQ + 纯 PL 方案

> 把锁相数据从 **FT245 USB (1–4 MB/s)** 迁移到 **千兆以太网 UDP (~100 MB/s)**，
> 整个工程仍是**纯 PL**，**不需要 PS 端写任何 ARM 代码**。

---

## 一、本次新增/修改的文件

| 路径 | 类型 | 说明 |
|---|---|---|
| `project_1.srcs/sources_1/new/udp_lockin_tx.v` | 新增 | 80 字节帧 → AXIS + UDP 包头适配器 |
| `project_1.srcs/sources_1/new/eth_phy_init.v` | 新增 | RTL8211E 上电硬复位时序 |
| `project_1.srcs/sources_1/new/eth_lockin_top.v` | 新增 | 顶层包装 (MMCM + CDC FIFO + 协议栈 + MAC) |
| `project_1.srcs/sources_1/new/lock_in_amp.v` | 修改 | 增加 PHY 端口 + 例化 `eth_lockin_top` |
| `project_1.srcs/constrs_1/new/eth_pins.xdc` | 新增 | RGMII 引脚 + 时序约束 + 异步时钟分组 |

> ⚠️ **现有 `pin.xdc` 不要改**，新约束都集中在 `eth_pins.xdc`，便于回滚。

---

## 二、外部依赖（必须做的事）

### 1. 下载 alexforencich/verilog-ethernet

> ⚠️ **不要**把第三方代码放在 `project_1.srcs/sources_1/` 里 — 那是 Vivado 给你自己代码的目录。
> 在**项目根目录**单独建一个 `third_party/`，并把它加进 `.gitignore`，避免污染本仓库 git 历史。

```bash
cd g:/xiao/git_pll
mkdir third_party
git clone --depth 1 https://github.com/alexforencich/verilog-ethernet.git third_party/verilog-ethernet
```

clone 后会得到：
```
third_party/verilog-ethernet/
├─ rtl/                  ← 我们要的核心
├─ lib/axis/rtl/         ← 我们要的 AXIS 通用模块
├─ example/              ← 参考例程, 不需要
├─ tb/ syn/ scripts/...  ← 不需要
```

### 2. Vivado 添加文件（**精确清单**）

**两步走**：先加 `verilog-ethernet/rtl/` 里**指定的 19 个文件**，再加 `lib/axis/rtl/` 里**指定的 5 个文件**。

> 不要一股脑把整个 `rtl/` 都加进来，里面有 10G/PTP/64bit 等等无关模块，会拖慢综合并产生一堆 critical warning。

#### 路径 A: `third_party/verilog-ethernet/rtl/` 中需要的文件 (19 个)

| 类别 | 文件 |
|---|---|
| **MAC + RGMII** | `eth_mac_1g_rgmii_fifo.v` `eth_mac_1g_rgmii.v` `eth_mac_1g.v` `axis_gmii_rx.v` `axis_gmii_tx.v` |
| **RGMII PHY 接口** | `rgmii_phy_if.v` `ssio_ddr_in.v` `ssio_ddr_out.v` `oddr.v` `iddr.v` |
| **CRC / FCS** | `lfsr.v` |
| **协议栈包装** | `eth_axis_rx.v` `eth_axis_tx.v` |
| **IP 层** | `ip_complete.v` `ip.v` `ip_eth_rx.v` `ip_eth_tx.v` `ip_arb_mux.v` `ip_demux.v` |
| **ARP** | `arp.v` `arp_cache.v` `arp_eth_rx.v` `arp_eth_tx.v` |
| **UDP 层** | `udp_complete.v` `udp.v` `udp_ip_rx.v` `udp_ip_tx.v` `udp_checksum_gen.v` |

#### 路径 B: `third_party/verilog-ethernet/lib/axis/rtl/` 中需要的文件 (5 个)

| 文件 |
|---|
| `axis_async_fifo.v` |
| `axis_async_fifo_adapter.v` |
| `axis_fifo.v` |
| `axis_arb_mux.v` |
| `arbiter.v` |
| `priority_encoder.v` |
| `sync_reset.v` |

### 3. Vivado **Add Sources** 操作（图形界面）

1. **Flow Navigator → Project Manager → Add Sources**
2. 选 **"Add or create design sources"** → Next
3. 点 **"Add Files"**（不要点 Add Directories，避免连带把 example/tb 加进来）
4. 浏览到 `third_party/verilog-ethernet/rtl/`, 按住 Ctrl 多选**清单 A 里那 24 个文件**
5. 再次 **Add Files**, 浏览到 `third_party/verilog-ethernet/lib/axis/rtl/`, 多选**清单 B 里那 7 个文件**
6. **重要：不要勾选** "Copy sources into project" — 让 Vivado 引用 `third_party/` 里的原始文件，方便后续 `git pull` 升级
7. Finish

### 4. 用 Tcl 一键添加（推荐）

如果觉得手点累，在 Vivado 的 **Tcl Console** 里粘贴这段一气搞定：

> ⚠️ **不要用 `[pwd]`**：Vivado 的 `pwd` 返回的是 Vivado 启动目录 (通常是
> `C:/Users/<user>/AppData/Roaming/Xilinx/Vivado/`)，**不是** `.xpr` 所在目录。
> 用 `get_property DIRECTORY [current_project]` 获取项目根目录最稳。

```tcl
# === 自动获取项目根目录 (.xpr 所在的目录) ===
set proj_root      [get_property DIRECTORY [current_project]]
set vlog_eth_rtl   $proj_root/third_party/verilog-ethernet/rtl
set vlog_axis_rtl  $proj_root/third_party/verilog-ethernet/lib/axis/rtl

puts "==> Project root: $proj_root"

# verilog-ethernet/rtl/  (33 个)
add_files -norecurse [list \
    $vlog_eth_rtl/eth_mac_1g_rgmii_fifo.v \
    $vlog_eth_rtl/eth_mac_1g_rgmii.v \
    $vlog_eth_rtl/eth_mac_1g.v \
    $vlog_eth_rtl/axis_gmii_rx.v \
    $vlog_eth_rtl/axis_gmii_tx.v \
    $vlog_eth_rtl/mac_ctrl_rx.v \
    $vlog_eth_rtl/mac_ctrl_tx.v \
    $vlog_eth_rtl/mac_pause_ctrl_rx.v \
    $vlog_eth_rtl/mac_pause_ctrl_tx.v \
    $vlog_eth_rtl/rgmii_phy_if.v \
    $vlog_eth_rtl/ssio_ddr_in.v \
    $vlog_eth_rtl/ssio_ddr_out.v \
    $vlog_eth_rtl/oddr.v \
    $vlog_eth_rtl/iddr.v \
    $vlog_eth_rtl/lfsr.v \
    $vlog_eth_rtl/eth_axis_rx.v \
    $vlog_eth_rtl/eth_axis_tx.v \
    $vlog_eth_rtl/eth_arb_mux.v \
    $vlog_eth_rtl/ip_complete.v \
    $vlog_eth_rtl/ip.v \
    $vlog_eth_rtl/ip_eth_rx.v \
    $vlog_eth_rtl/ip_eth_tx.v \
    $vlog_eth_rtl/ip_arb_mux.v \
    $vlog_eth_rtl/ip_demux.v \
    $vlog_eth_rtl/arp.v \
    $vlog_eth_rtl/arp_cache.v \
    $vlog_eth_rtl/arp_eth_rx.v \
    $vlog_eth_rtl/arp_eth_tx.v \
    $vlog_eth_rtl/udp_complete.v \
    $vlog_eth_rtl/udp.v \
    $vlog_eth_rtl/udp_ip_rx.v \
    $vlog_eth_rtl/udp_ip_tx.v \
    $vlog_eth_rtl/udp_checksum_gen.v \
]

# verilog-ethernet/lib/axis/rtl/  (8 个)
add_files -norecurse [list \
    $vlog_axis_rtl/axis_async_fifo.v \
    $vlog_axis_rtl/axis_async_fifo_adapter.v \
    $vlog_axis_rtl/axis_adapter.v \
    $vlog_axis_rtl/axis_fifo.v \
    $vlog_axis_rtl/axis_arb_mux.v \
    $vlog_axis_rtl/arbiter.v \
    $vlog_axis_rtl/priority_encoder.v \
    $vlog_axis_rtl/sync_reset.v \
]

update_compile_order -fileset sources_1
puts "==> verilog-ethernet sources added (41 files total)"
```

执行后会一次性导入 41 个文件 (33 + 8)，并自动更新编译顺序。

> **关于 `altddio_in` / `altddio_out` 红问号**：这是 `iddr.v` / `oddr.v` 里 ALTERA
> 分支的引用，本工程 `TARGET="XILINX"` 综合时不会用到，**可以忽略**。
> 强迫症可以加 stub 模块，但不推荐 (会污染第三方库).
第一行 `puts "==> Project root: ..."` 会回显你的实际项目根目录，应该是
`G:/xiao/git_pll`，否则路径就不对。

#### 备选方案: 直接写绝对路径

如果上面 `get_property` 方式还是有问题（少数旧版 Vivado 没打开项目时不可用），
可以直接把 `set proj_root` 那行换成绝对路径硬编码：

```tcl
set proj_root G:/xiao/git_pll
```

### 5. 把 `third_party/` 加入 git 忽略

已经帮你在 `.gitignore` 末尾添加：
```gitignore
third_party/
```
所以这个目录**不会被 git 追踪**，但本地仍然能用。其他人 clone 你的仓库后，按本文档第二节命令再 clone 一次 verilog-ethernet 即可。

### 2. 在 Vivado IP Catalog 生成 `clk_wiz_eth`

```
IP Catalog → Search "Clocking Wizard" → 双击
- Component Name: clk_wiz_eth
- Input Clock 1: 50 MHz, Frequency Synthesis ✓, Buffer ✓
- Output Clock 1: 125 MHz, 0°
- Output Clock 2: 125 MHz, 90°
- Locked output ✓
- Reset Type: Active high
- 其他保持默认 → Generate
```

### 3. (可选) 启用 XPM 库

确保 `project_1.xpr` 中 `set_property -name "XPM_LIBRARIES" -value "XPM_FIFO" -objects $obj` 存在。
默认 Vivado 工程会自动使能 XPM，如果不放心可以在 Tcl 控制台跑：
```tcl
set_property XPM_LIBRARIES {XPM_FIFO} [current_project]
```

---

## 三、Vivado 工程操作步骤

### 步骤 A: 添加源文件
1. **Add Sources → Add or Create Design Sources**
2. 添加自有源码:
   - `project_1.srcs/sources_1/new/udp_lockin_tx.v`
   - `project_1.srcs/sources_1/new/eth_phy_init.v`
   - `project_1.srcs/sources_1/new/eth_lockin_top.v`
   - 修改后的 `lock_in_amp.v` (会自动检测)
3. 添加第三方源码: 参见上面**第二节"4. 用 Tcl 一键添加"** ★ 推荐

### 步骤 B: 添加约束
1. **Add Sources → Add or Create Constraints**
2. 勾选 `project_1.srcs/constrs_1/new/eth_pins.xdc`

### 步骤 C: 生成 IP
1. 打开 **IP Catalog**, 按上面"步骤 2"生成 `clk_wiz_eth`
2. **Generate Output Products**

### 步骤 D: 综合 & 实现
1. **Run Synthesis** — 期望: 0 error, ≤ 几个 critical warning（关于 RGMII IDELAY 之类的可以忽略）
2. **Run Implementation** — 期望: 时序通过 (WNS > 0)
3. **Generate Bitstream**

### 步骤 E: 上板调试
1. 烧录 bitstream
2. PC 网卡静态 IP 设为 `192.168.1.100`，子网掩码 `255.255.255.0`
3. 用网线**直连** FPGA 板和 PC（不要经过路由器，避免 DHCP 干扰）
4. PL_LED1 亮表示链路 1G 已建立

---

## 四、PC 端 Python 接收脚本

```python
# eth_recv.py - 替代 PySerial 接收
import socket, struct, time

UDP_PORT = 7777
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(('0.0.0.0', UDP_PORT))
print(f"Listening on UDP :{UDP_PORT} ...")

frames = 0
t0 = time.time()
while True:
    data, addr = sock.recvfrom(2048)
    if len(data) != 80:
        continue
    sync = data[:4]
    if sync != b'\xA5\x5A\xA5\x5A':
        print(f"BAD SYNC: {sync.hex()}")
        continue
    
    # 按 lock_in_amp.v 注释里的偏移解析 (大端 int32)
    dc_x_ch1 = struct.unpack('>i', data[4:8])[0]
    dc_y_ch1 = struct.unpack('>i', data[8:12])[0]
    dc_x_ch2 = struct.unpack('>i', data[12:16])[0]
    dc_y_ch2 = struct.unpack('>i', data[16:20])[0]
    # ... 其余字段同 FT245 协议
    
    pll_freq_ch1 = struct.unpack('>Q', data[60:68])[0]
    pll_freq_ch2 = struct.unpack('>Q', data[68:76])[0]
    lock_flags   = struct.unpack('>i', data[76:80])[0]
    
    frames += 1
    if frames % 1000 == 0:
        rate = frames / (time.time() - t0)
        print(f"frames={frames}, rate={rate:.1f} fps, "
              f"X1={dc_x_ch1}, Y1={dc_y_ch1}, "
              f"F1={pll_freq_ch1}, lock={lock_flags & 0x3}")
```

运行：
```bash
python eth_recv.py
```

---

## 五、调试 Checklist & 故障排查

### Checklist 上电首次调试
- [ ] PHY 灯亮（板上 RJ45 旁的绿/橙灯）→ 物理层连通
- [ ] PL_LED1 亮 → MAC 检测到 1Gbps 链路
- [ ] Wireshark 抓到 ARP `who-has 192.168.1.10` 来自 FPGA
- [ ] PC ping FPGA 不通是正常的（我们没实现 ICMP），ARP 通就行
- [ ] Wireshark 看到 UDP 包源 IP = 192.168.1.10、目的端口 7777
- [ ] Python 脚本收到 80 字节包、sync 校验通过

### 常见故障

| 现象 | 原因 | 排查 |
|---|---|---|
| PL_LED1 不亮 | PHY 没复位好 / 链路没建立 | 看 `eth_nrst` 是否拉高、PHY 灯是否亮、网线是否好 |
| Wireshark 完全没包 | RGMII 时钟方向错 / IDELAY 没对齐 | 查 `eth_txc` 是不是 ODDR 输出、改用 `clk125_90` 驱动 |
| 抓到包但 CRC 错 | RX/TX 内部延迟没匹配 | 用 MDIO 写 PHY 寄存器关闭/打开 RGMII delay (RTL8211E 寄存器 0x18 bit 1)，或在 FPGA 端加 IDELAY |
| 包长正确但 sync 总是错 | 字节序错 | 检查 `udp_lockin_tx` 是从 MSB 开始串行的 |
| 偶尔丢包 | 网络环境差 / FIFO 满 | PL_LED2 闪表示 `frame_dropped`，加大 `XPM_FIFO_ASYNC` 深度到 64 |
| Vivado 报 `eth_mac_1g_rgmii_fifo` 找不到 | verilog-ethernet 没加进工程 | 重新 Add Sources |

### 抓包神器: Wireshark 过滤式

```
udp.port == 7777                  # 只看锁相数据
arp.src.proto_ipv4 == 192.168.1.10  # 看 FPGA 发的 ARP
```

---

## 六、扩展空间

### 6.1 加大数据率（后续可做）
当前 80 字节/帧：

- 设锁相 valid 速率 1 MHz → 80 MB/s（千兆余量足够）
- 想加波形上传 → 把 `x_y_fir_packed` 扩成 1 KB / 帧，速率不变也能跑 1 GB/s（千兆物理上限 ~110 MB/s 还远没到）

### 6.2 加 UDP 下行命令（替代 UART）

把 `udp_complete` 的 RX 输出（当前我接到了 `tready=1` 全部丢弃）接到 `usb_commend` 的命令解析端，就能用 UDP 替代 UART，实现纯网线控制。

### 6.3 加 TCP（如果以后要做远程操控）

PL 实现 TCP 太复杂，**到这一步建议切到 PS GEM + lwIP 方案**。

---

## 七、性能预期

| 指标 | 预期值 | 备注 |
|---|---|---|
| 链路速率 | 1000 Mbps | RTL8211E 自动协商 |
| 应用层带宽（UDP 单流） | 80–110 MB/s | 远超 FT245 |
| 单包发送延迟 | < 5 µs | 帧装包到 RGMII 输出 |
| FPGA 资源占用 (XC7Z020) | ≈ 5–8% LUT, 1 BRAM | 协议栈是大头 |
| 时钟资源 | 1 个 MMCM | clk_wiz_eth |

---

## 八、回退方案

如果以太网方案出问题，**FT245 上行通路保持完好**（`u_usb_commend / u_ft245_tx` 模块没被删除），直接按原工程烧录就回到 USB 模式。两条路径并行存在，互不干扰。

---

*文档生成日期: 2026-05-06*
*作者: Cursor Agent*
*依赖版本: alexforencich/verilog-ethernet @ master (2024+)*
