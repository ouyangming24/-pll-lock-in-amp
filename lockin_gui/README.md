# 双通道数字锁相放大器 GUI

商用锁相放大器风格的实时数据采集与控制软件，配套本仓库的 FPGA 工程。

## 功能

- ✅ 11 路锁相数据实时波形显示（Ch1/Ch2/Ch3 全频点）
- ✅ 极坐标 R-θ 显示
- ✅ PI 系数、IIR 时常数、扫频起点频率、相位偏移**热修改**
- ✅ FPS 帧率监测、PLL 锁定状态指示
- ✅ CSV 录制保存
- ✅ **3 种通信模式**：USB 串口 / 以太网 UDP / 离线模拟

## 安装

```bash
cd lockin_gui
pip install -r requirements.txt
```

## 运行

支持 3 种工作模式：

### 1. 串口模式（默认）

`PC <─ FT245 USB ─> FPGA`，命令和数据**都走 USB**。FPGA 端使用传统 FT245BL 上下行通道。

```bash
python main.py
```

界面操作：
1. 顶栏选择 COM 端口 → 点 **连接**
2. 调整参数（KP / KI / TAU / 频率…）→ 点参数旁的 **▶** 下发
3. 点 **开始数据流** → 实时波形开始刷新
4. 需要保存 → 点 **录制 CSV**

### 2. 以太网 UDP 模式 ★

```
PC <─ FT245 USB ─> FPGA   (命令)
PC <─ 网线 UDP   ─> FPGA   (数据, 千兆 RGMII)
```

数据通道走以太网，可达千兆速率。命令通道仍走 FT245 串口（FPGA 端 `usb_commend` 模块没有 UDP 输入；后续可以切换）。

```bash
python main.py --udp
```

启动前需要 PC 网卡配置：

| 项 | 值 |
|----|----|
| IP 地址 | `192.168.99.100` |
| 子网掩码 | `255.255.255.0` |
| 默认网关 | （留空） |

> 故意用 `192.168.99.x` 子网避免和家用路由器 `192.168.1.x` 冲突。  
> FPGA 默认 IP 是 `192.168.99.10`，可在 `lock_in_amp.v` 里改 `LOCAL_IP` 参数。

界面操作和串口模式一样，**唯一区别是顶栏选择的 COM 端口仅用于发命令**，数据从网卡进来，不走串口。

> 第一次连接以太网 UDP 模式后，FPGA 上电时会做 IDELAY 自动扫描，约 50 秒后才能开始收数据。这期间 GUI 状态栏 FPS 显示 0.0 是正常的。

### 3. 离线模拟模式（无板子）

```bash
python main.py --demo
```

GUI 里所有控件可用，数据来自内置模拟器（产生正弦 + 噪声）。

## 目录结构

```
lockin_gui/
├── main.py            # 启动入口 (3 种模式)
├── device.py          # LockinDevice (串口) + UdpLockinDevice (以太网) + MockDevice (模拟)
├── main_window.py     # PyQt5 主窗口 (与具体设备类型解耦, 完全面向接口)
├── requirements.txt   # 依赖
└── README.md          # 本文档
```

`device.py` 提供 3 个 `QObject` 设备类，全部发出相同的 4 个信号：

- `frame_received(dict)`     ── 收到一帧锁相数据
- `log_message(str)`         ── 日志
- `connection_changed(bool)` ── 连接状态
- `cmd_response(str)`        ── 命令响应

`main_window.py` 不关心具体是哪个类，全部通过这 4 个信号驱动 UI。

## 命令行调试工具

如果你只想在不开 GUI 的情况下验证以太网 UDP 链路是否通：

```bash
python ../tools/host_udp.py
```

这个脚本和 `--udp` 模式用同样的协议解析逻辑，但只打印每秒 fps，便于做简单连通性 / 性能验证。

## 协议

详见 `../docs/Interface_Spec_for_SW.md`，本 GUI 严格按规约实现。

## 以太网通信迁移笔记

完整的 FPGA 端以太网迁移过程（IDELAY 扫描、PHY 复位、RGMII 时序、`USE_CLK90` 翻面调试）见 `../docs/ethernet_migration_plan.md`。
