# 双通道数字锁相放大器 GUI

商用锁相放大器风格的实时数据采集与控制软件，配套本仓库的 FPGA 工程（FT245BL 通信）。

## 功能

- ✅ 11 路锁相数据实时波形显示（Ch1/Ch2/Ch3 全频点）
- ✅ 极坐标 R-θ 显示
- ✅ PI 系数、IIR 时常数、扫频起点频率、相位偏移**热修改**
- ✅ FPS 帧率监测、PLL 锁定状态指示
- ✅ CSV 录制保存
- ✅ **离线模拟模式**：没板子也能开发界面

## 安装

```bash
cd lockin_gui
pip install -r requirements.txt
```

## 运行

### 真实硬件模式

把 FPGA 板子的 FT245BL 通过 USB 连到 PC（VCP 模式），然后：

```bash
python main.py
```

界面打开后：
1. 顶栏选择 COM 端口 → 点 **连接**
2. 调整参数（KP / KI / TAU / 频率…）→ 点参数旁的 **▶** 下发
3. 点 **开始数据流** → 实时波形开始刷新
4. 需要保存 → 点 **录制 CSV**

### 离线模拟模式（无板子）

```bash
python main.py --demo
```

GUI 里所有控件可用，数据来自内置模拟器（产生正弦 + 噪声）。

## 目录结构

```
lockin_gui/
├── main.py            # 启动入口
├── device.py          # 设备通信 + 帧解析 + Mock 模拟器
├── main_window.py     # PyQt5 主窗口
├── requirements.txt   # 依赖
└── README.md          # 本文档
```

## 协议

详见 `../docs/Interface_Spec_for_SW.md`，本 GUI 严格按规约实现。
