"""
main_window.py
──────────────
PyQt5 主窗口 ── 商用锁相放大器风格 GUI

布局 (2x2):
┌────────────────────────────────┬────────────────────────────────┐
│ 通道1 PLL 锁定频率 F1(t)        │ 通道2 PLL 锁定频率 F2(t)        │
│ F1 = 1234.567 Hz  [🟢锁定]     │ F2 = 5678.901 Hz  [🟢锁定]     │
├────────────────────────────────┼────────────────────────────────┤
│ 通道3 谐波 + DC (多曲线)        │ 通道3 ADC 输入波形             │
│  信号▼ 分量▼ [+添加] [清空]    │                                │
│  [● 2F1+F2·X ×] [● F1+F2·R ×] │                                │
└────────────────────────────────┴────────────────────────────────┘
"""

import csv
import math
import time
from collections import deque

import numpy as np
import pyqtgraph as pg
from PyQt5.QtCore import Qt, QTimer
from PyQt5.QtGui import QFont
from PyQt5.QtWidgets import (
    QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QGridLayout,
    QGroupBox, QLabel, QLineEdit, QPushButton, QComboBox, QRadioButton,
    QPlainTextEdit, QFileDialog, QSplitter, QStatusBar, QFrame,
    QSizePolicy,
)

from device import (
    LockinDevice, UdpLockinDevice, MockDevice, list_serial_ports,
    hz_to_freq_word, FIELD_NAMES,
)

# ============================================================================
# 配置
# ============================================================================
PLOT_BUF = 1000           # 每条曲线显示点数 (2000 → 1000, 减半绘图压力)
REFRESH_HZ = 15           # 绘图刷新率 (20 → 15, GUI 不再卡)
PEN_W = 1.2               # 线宽稍降, 配合关闭抗锯齿后视觉差别极小

# 通道3 谐波多曲线绘图调色板 (循环使用, 8 色覆盖所有 4×4 组合都足够区分)
HAR_PALETTE = [
    "#5d5",   # 亮绿
    "#f63",   # 橙红
    "#4af",   # 浅蓝
    "#fc5",   # 金黄
    "#a6f",   # 紫
    "#0cc",   # 青
    "#f69",   # 粉
    "#9c6",   # 黄绿
]

# CIC 降采样后 IIR 实际工作的采样率 (Hz). 与 lock_in_amp.v 中
# cic_compiler_0 的 Fixed_Or_Initial_Rate=65 + 输入 65MHz 一致 → 1 MHz
IIR_FS_HZ = 1_000_000

TAU_MIN = 0
TAU_MAX = 31              # shift_k 是 5bit, 硬件支持上限


# ============================================================================
# 电压换算 (锁相 dc_x / dc_y / dc_dc 码值 → 物理电压)
# ============================================================================
# 信号链:
#   V_in (峰值 V0, ±10V 量程) ──ADC──▶ 14bit (±2^13 = ±8192 对应 ±V_FS)
#   adc_code = V_in × 2^13 / V_FS
#         ──× DDS(14b sin/cos, 满振幅 2^13)──▶ 28bit mix (signed)
#         ──CIC(R=65,M=1,N=5, Truncation)──▶ 28bit cic
#         ──IIR EMA(单位增益)──▶ dc_x / dc_y
#
# 端到端增益 G_total = (2^13/V_FS) × 2^13 × 0.5 × G_cic
#   2^13/V_FS:  ADC 模拟 → 码值
#   × 2^13:     混频 DDS 振幅 (Xilinx DDS Compiler 默认满量程)
#   × 0.5:      cos·cos = (1+cos2ω)/2, CIC 后只剩 1/2 DC
#   × G_cic:    CIC Truncation 实际增益 = (R·M)^N / 2^growth
#
# Xilinx CIC IP Truncation 模式:
#   growth = ceil(N * log2(R*M)) = ceil(5*log2(65)) = 31
#   G_cic_eff = 65^5 / 2^31 ≈ 0.5403 (CIC 截位后稍微衰减, 这是正常的)
#
# 对幅度为 V0 的正弦输入, 锁定后 R = sqrt(X²+Y²) = V0 × G_total
#   → V0 = R / G_total   (V0 是输入信号的"峰值幅度", 不是峰峰值, 也不是 rms)
ADC_FS_V = 10.0         # ADC 模拟输入满量程 (±10V, 即峰峰值 20V).
                        # 依据: ad_wave_rec.v 注释 "(ADC_DATA - 8192) * (20/16384)",
                        # 14bit unsigned, 0~16383 对应 -10V~+10V (offset binary 或 2's complement
                        # 取决于硬件 SPI 配置; 两种格式下 G_total 推导结果完全一致).
ADC_BITS = 14           # ADC 位宽 (signed, 振幅 ±2^13)
DDS_BITS = 14           # DDS 输出位宽 (signed, 振幅 ±2^13)
CIC_R = 65              # CIC 抽取率
CIC_M = 1               # CIC 差分延迟
CIC_N = 5               # CIC 级数

_CIC_GROWTH = math.ceil(CIC_N * math.log2(CIC_R * CIC_M))   # = 31
CIC_GAIN_EFF = (CIC_R * CIC_M) ** CIC_N / (1 << _CIC_GROWTH)  # ≈ 0.5403

G_TOTAL = (
    (1 << (ADC_BITS - 1)) / ADC_FS_V       # ADC 码值 / V
    * (1 << (DDS_BITS - 1))                # × DDS 满振幅
    * 0.5                                  # × cos²ω 的 DC 系数
    * CIC_GAIN_EFF                         # × CIC 截位实际增益
)
# 例: V_FS=5V, ADC/DDS 14bit, CIC(65,1,5) → G_TOTAL ≈ 3,626,240

# 实测标定系数: 用已知幅度正弦波 (如 100 mV 峰值 @ 50 kHz) 注入 ADC,
# 计算 CALIB_K = (实际 V0 mV) / (GUI 显示的 R mV), 然后改下面这个常数.
# 默认 1.0 表示用理论值, 实测后微调以补偿 ADC 增益误差/前端电路偏差等.
CALIB_K = 1.0

V_PER_LSB = CALIB_K / G_TOTAL              # 码值 → V
MV_PER_LSB = V_PER_LSB * 1000.0            # 码值 → mV (≈ 2.758e-4 mV)


def tau_to_fc_hz(k: int, fs: float = IIR_FS_HZ) -> float:
    """tau (shift_k) → 一阶 IIR EMA 的 -3dB 截止频率 (Hz).
    精确公式: cos(ω) = 1 − α²/(2(1−α)),  α = 2^-k,  fc = ω·fs/(2π).
    """
    if k <= 0:
        return float("inf")
    alpha = 2.0 ** (-k)
    cos_w = 1.0 - alpha * alpha / (2.0 * (1.0 - alpha))
    cos_w = max(-1.0, min(1.0, cos_w))
    return math.acos(cos_w) * fs / (2.0 * math.pi)


def tau_to_fc_label(text: str) -> tuple[str, bool]:
    """根据用户输入的 tau 字符串返回 (显示文本, 是否合法).
    合法范围: 0 ~ 31 的整数. 0 = 无滤波, 越大截止频率越低.
    """
    try:
        k = int(text.strip())
    except (ValueError, AttributeError):
        return ("非法", False)
    if k < TAU_MIN or k > TAU_MAX:
        return (f"超范围 ({TAU_MIN}~{TAU_MAX})", False)
    if k == 0:
        return ("≈ 全通 (无滤波)", True)
    fc = tau_to_fc_hz(k)
    if fc >= 1000:
        return (f"fc ≈ {fc/1000:7.2f} kHz", True)
    if fc >= 1:
        return (f"fc ≈ {fc:7.2f} Hz", True)
    if fc >= 0.001:
        return (f"fc ≈ {fc*1000:7.2f} mHz", True)
    return (f"fc ≈ {fc*1e6:7.2f} µHz", True)

# pyqtgraph 全局 - 关闭抗锯齿 + (可选)启用 OpenGL 硬件加速
pg.setConfigOption("background", "#1e1e1e")
pg.setConfigOption("foreground", "#dddddd")
pg.setConfigOption("antialias", False)        # ★ 关闭抗锯齿: 单帧绘制成本降到 1/3

# 尝试启用 OpenGL 硬件加速; 若未安装 PyOpenGL 则回退为 CPU 软渲染
try:
    import OpenGL  # noqa: F401  仅检测包是否可用
    pg.setConfigOption("useOpenGL", True)
    pg.setConfigOption("enableExperimental", True)
    _USE_OPENGL = True
except ImportError:
    _USE_OPENGL = False


# ============================================================================
# 锁定指示灯 + 频率显示组合 widget
# ============================================================================
class ChannelHeader(QWidget):
    """显示在每个绘图上方:  [标题]  Fx = xxx.xxx Hz   ●LOCK"""

    def __init__(self, title: str, freq_label: str = "F"):
        super().__init__()
        self.freq_label = freq_label
        h = QHBoxLayout(self)
        h.setContentsMargins(6, 2, 6, 2)
        h.setSpacing(15)

        self.lbl_title = QLabel(title)
        self.lbl_title.setStyleSheet("color:#4af; font-weight:bold; font-size:11pt;")
        h.addWidget(self.lbl_title)

        self.lbl_freq = QLabel(f"{freq_label} = ─── Hz")
        self.lbl_freq.setStyleSheet("color:#fff; font-family:Consolas; font-size:11pt;")
        self.lbl_freq.setMinimumWidth(220)
        h.addWidget(self.lbl_freq)

        h.addStretch()

        self.lbl_led = QLabel("●")
        self.lbl_led.setFixedWidth(18)
        self.lbl_led.setStyleSheet("color:#888; font-size:18pt;")  # 灰: 未锁
        h.addWidget(self.lbl_led)

        self.lbl_state = QLabel("UNLOCKED")
        self.lbl_state.setMinimumWidth(80)
        self.lbl_state.setStyleSheet("color:#888; font-weight:bold; font-size:10pt;")
        h.addWidget(self.lbl_state)

    def update(self, freq_hz: float, locked: bool):
        if freq_hz < 1e-3:
            self.lbl_freq.setText(f"{self.freq_label} = ─── Hz")
        else:
            self.lbl_freq.setText(f"{self.freq_label} = {freq_hz:>11.3f} Hz")
        if locked:
            self.lbl_led.setStyleSheet("color:#3f3; font-size:18pt;")  # 亮绿
            self.lbl_state.setText("LOCKED")
            self.lbl_state.setStyleSheet("color:#3f3; font-weight:bold;")
        else:
            self.lbl_led.setStyleSheet("color:#888; font-size:18pt;")
            self.lbl_state.setText("UNLOCKED")
            self.lbl_state.setStyleSheet("color:#888; font-weight:bold;")


# ============================================================================
# 单个绘图面板 (header + pyqtgraph plot)
# ============================================================================
class PlotPanel(QFrame):
    def __init__(self, title: str, freq_label: str | None = None,
                 y_label: str = "幅值"):
        super().__init__()
        self.setFrameShape(QFrame.StyledPanel)
        self.setStyleSheet("QFrame { background:#222; border:1px solid #444; border-radius:4px; }")

        v = QVBoxLayout(self)
        v.setContentsMargins(2, 2, 2, 2)
        v.setSpacing(2)

        if freq_label:
            self.header = ChannelHeader(title, freq_label)
            v.addWidget(self.header)
        else:
            self.header = None
            lbl = QLabel(f"  {title}")
            lbl.setStyleSheet("color:#4af; font-weight:bold; font-size:11pt;")
            v.addWidget(lbl)

        self.plot = pg.PlotWidget()
        self.plot.showGrid(x=True, y=True, alpha=0.3)
        self.plot.setLabel("bottom", "时间", units="s")
        self.plot.setLabel("left", y_label)
        self.plot.addLegend(offset=(10, 10), labelTextSize="9pt")
        # 性能优化: 自动降采样 + 视口裁剪 + 鼠标事件不强制重绘
        self.plot.setDownsampling(auto=True, mode="peak")
        self.plot.setClipToView(True)
        self.plot.setAntialiasing(False)
        # 关闭"鼠标右键拖动 = auto-range"等会导致回调风暴的特性
        self.plot.getPlotItem().getViewBox().setMouseEnabled(x=True, y=True)
        v.addWidget(self.plot, 1)


# ============================================================================
# 主窗口
# ============================================================================
class MainWindow(QMainWindow):
    def __init__(self, demo_mode: bool = False, udp_mode: bool = False):
        super().__init__()
        self.setWindowTitle("数字锁相放大器 · 双通道 · 三谐波检测")
        self.resize(1500, 900)

        if demo_mode:
            self.dev = MockDevice()
        elif udp_mode:
            self.dev = UdpLockinDevice()
        else:
            self.dev = LockinDevice()
        self.dev.frame_received.connect(self.on_frame)
        self.dev.log_message.connect(self.on_log)
        self.dev.connection_changed.connect(self.on_conn_changed)

        # 数据缓冲区
        # FIELD_NAMES 是 80 字节帧的原始字段; 这里再额外存两个派生的 Hz 频率轨迹
        self.buf = {k: deque(maxlen=PLOT_BUF) for k in FIELD_NAMES}
        self.buf["pll_freq_ch1_hz"] = deque(maxlen=PLOT_BUF)
        self.buf["pll_freq_ch2_hz"] = deque(maxlen=PLOT_BUF)
        self.t_buf = deque(maxlen=PLOT_BUF)
        self.frame_count = 0
        self._fps_t0 = time.time()
        self._fps = 0.0

        # 当前帧的派生量 (用于 header 显示)
        self._latest_freq_ch1 = 0.0
        self._latest_freq_ch2 = 0.0
        self._latest_locked_ch1 = False
        self._latest_locked_ch2 = False
        self._last_frame: dict | None = None    # 最近一帧解析结果, 供诊断按钮使用

        self.csv_writer = None
        self.csv_file = None

        self._build_ui()

        self.refresh_timer = QTimer()
        self.refresh_timer.timeout.connect(self.refresh_plots)
        self.refresh_timer.start(int(1000 / REFRESH_HZ))

        # 启动时给一条性能模式提示
        backend = "OpenGL (GPU)" if _USE_OPENGL else "Raster (CPU)"
        self.on_log(f"[+] 渲染后端: {backend}    刷新率: {REFRESH_HZ} Hz    缓冲: {PLOT_BUF}")
        if not _USE_OPENGL:
            self.on_log("    ↳ 未检测到 PyOpenGL, 使用 CPU 渲染. "
                        "如鼠标卡顿可: pip install PyOpenGL")

    # ============================================================ UI 构造
    def _build_ui(self):
        # 顶栏
        top_bar = QHBoxLayout()
        top_bar.setSpacing(8)
        top_bar.addWidget(QLabel("端口"))
        self.port_combo = QComboBox()
        self.port_combo.setMinimumWidth(110)
        self._refresh_ports()
        top_bar.addWidget(self.port_combo)
        self.btn_refresh_ports = QPushButton("⟳")
        self.btn_refresh_ports.setMaximumWidth(30)
        self.btn_refresh_ports.clicked.connect(self._refresh_ports)
        top_bar.addWidget(self.btn_refresh_ports)
        self.btn_connect = QPushButton("连接")
        self.btn_connect.clicked.connect(self.on_connect_clicked)
        top_bar.addWidget(self.btn_connect)
        top_bar.addSpacing(20)
        self.btn_stream = QPushButton("开始数据流")
        self.btn_stream.setEnabled(False)
        self.btn_stream.clicked.connect(self.on_stream_clicked)
        top_bar.addWidget(self.btn_stream)
        top_bar.addSpacing(20)
        self.btn_record = QPushButton("录制 CSV")
        self.btn_record.setEnabled(False)
        self.btn_record.clicked.connect(self.on_record_clicked)
        top_bar.addWidget(self.btn_record)
        top_bar.addStretch()
        if isinstance(self.dev, MockDevice):
            mode_text, mode_color = "DEMO 模式", "#ff9"
        elif isinstance(self.dev, UdpLockinDevice):
            mode_text, mode_color = "以太网 UDP 模式", "#5df"
        else:
            mode_text, mode_color = "串口模式 (FT245)", "#ff9"
        self.lbl_mode = QLabel(mode_text)
        self.lbl_mode.setStyleSheet(f"color: {mode_color}; font-weight: bold;")
        top_bar.addWidget(self.lbl_mode)

        # 左侧参数面板 / 右侧绘图区
        left = self._build_param_panel()
        right = self._build_plot_area()

        splitter = QSplitter(Qt.Horizontal)
        splitter.addWidget(left)
        splitter.addWidget(right)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        splitter.setChildrenCollapsible(False)
        splitter.setSizes([460, 1040])
        self.splitter = splitter   # ★ 保存引用, resizeEvent 强制左侧宽度不缩水
        self._left_panel_w = 460   # 与上面 setSizes 一致, resizeEvent 会引用此值

        central = QWidget()
        v = QVBoxLayout(central)
        v.setContentsMargins(8, 8, 8, 0)
        v.addLayout(top_bar)
        v.addWidget(splitter, 1)
        self.setCentralWidget(central)

        self.status = QStatusBar()
        self.setStatusBar(self.status)
        self.lbl_status_conn = QLabel("● 未连接")
        self.lbl_status_fps = QLabel("FPS: --")
        self.lbl_status_buf = QLabel("缓冲: 0/0")
        self.lbl_status_rec = QLabel("")
        for w in (self.lbl_status_conn, self.lbl_status_fps,
                  self.lbl_status_buf, self.lbl_status_rec):
            self.status.addPermanentWidget(w)

        self._set_dark_theme()

    # ------------------------------------------------------------- 参数面板
    def _build_param_panel(self) -> QWidget:
        panel = QWidget()
        # ★ 固定参数面板宽度: 不随窗口最大化而被 QSplitter 比例缩放压扁.
        #   setFixedWidth 是强制宽度, 比 setMinimumWidth + setMaximumWidth 更可靠.
        panel.setFixedWidth(460)
        panel.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Expanding)
        v = QVBoxLayout(panel)
        v.setSpacing(6)

        gb_pll = QGroupBox("PLL 锁相环参数")
        g_pll = QGridLayout(gb_pll)
        self._setup_normal_grid(g_pll)
        self.ed_kp = self._mk_param_row(g_pll, 0, "KP", "500", "KP")
        self.ed_ki = self._mk_param_row(g_pll, 1, "KI", "50", "KI")
        v.addWidget(gb_pll)

        gb_tau = QGroupBox(f"⚙ IIR 滤波时间常数  (k = {TAU_MIN} ~ {TAU_MAX}, fs = {IIR_FS_HZ/1e6:.0f} MHz)")
        gb_tau.setObjectName("gbHighlight")
        gb_tau.setToolTip(
            "k 是 IIR 一阶 EMA 的位移量 (shift_k), 滤波器系数 α = 2^-k.\n"
            f"采样率 fs = {IIR_FS_HZ/1e6:.0f} MHz (CIC 降采样后).\n"
            "k 越大 → 截止频率 fc 越低, 滤波越慢, 噪声越小.\n"
            "k = 0 表示无滤波 (全通), k 范围 0~31."
        )
        g_tau = QGridLayout(gb_tau)
        g_tau.setVerticalSpacing(6)
        g_tau.setHorizontalSpacing(8)
        g_tau.setContentsMargins(10, 14, 10, 10)
        # ★ 所有列固定: Label(95) + LineEdit(115) + fc(145) + Btn(42) + 3×间距(24) + 边距(20) = 441
        #   panel 固定 460, 边距余 19px 自然贴右边, 完全不受 resize 影响.
        g_tau.setColumnStretch(0, 0)
        g_tau.setColumnStretch(1, 0)
        g_tau.setColumnStretch(2, 0)
        g_tau.setColumnStretch(3, 0)
        g_tau.setColumnStretch(4, 1)   # 末尾加一个虚拟"吸收列"消化富余
        self.ed_t1x  = self._mk_tau_row(g_tau, 0,  "CH1_X (PLL)",       "20", "TAU1X")
        self.ed_t1y  = self._mk_tau_row(g_tau, 1,  "CH1_Y (PLL)",       "8",  "TAU1Y")
        self.ed_t2x  = self._mk_tau_row(g_tau, 2,  "CH2_X (PLL)",       "20", "TAU2X")
        self.ed_t2y  = self._mk_tau_row(g_tau, 3,  "CH2_Y (PLL)",       "8",  "TAU2Y")
        # 通道3 三路谐波: X/Y 共用单一 TC (与商用 SR830 等保持一致), 不分开设置
        self.ed_t21  = self._mk_tau_row(g_tau, 4,  "2F1+F2 (谐波)",     "20", "TAU21")
        self.ed_t12  = self._mk_tau_row(g_tau, 5,  "F1+2F2 (谐波)",     "20", "TAU12")
        self.ed_t11  = self._mk_tau_row(g_tau, 6,  "F1+F2  (谐波)",     "20", "TAU11")
        self.ed_tdc  = self._mk_tau_row(g_tau, 7,  "DC (无混频)",       "20", "TAUDC")
        v.addWidget(gb_tau)

        # ★ IIR 阶数 (CH3 各路独立) — 每路独立选择 1..4 阶
        #   实现: N 个相同 tau 的一阶 EMA 串联 (与 SR860 / Zurich MFLI 每通道独立 slope 一致).
        #   每加一阶, 阻带衰减斜率 +6 dB/oct, 建立时间 ≈ N · τ_单阶.
        gb_ord = QGroupBox("⚙ IIR 阶数 (CH3 各路独立, 1..4 阶 = 6/12/18/24 dB/oct)")
        gb_ord.setObjectName("gbHighlight")
        gb_ord.setToolTip(
            "通道3 每路 IIR 滤波器单独设置阶数 (3 路谐波 + DC 共 4 个独立设置).\n"
            "实现: N 个相同 tau 的一阶 EMA 级联 (无过冲, 时域单调收敛).\n"
            "阶数 ↑  → 阻带斜率 ↑ (噪声抑制 ↑), 建立时间 ≈ N · τ_单阶."
        )
        g_ord = QGridLayout(gb_ord)
        g_ord.setVerticalSpacing(6)
        g_ord.setHorizontalSpacing(8)
        g_ord.setContentsMargins(10, 14, 10, 10)
        # ★ 全部固定宽度, 末尾加吸收列消化富余
        g_ord.setColumnStretch(0, 0)
        g_ord.setColumnStretch(1, 0)
        g_ord.setColumnStretch(3, 0)
        g_ord.setColumnStretch(4, 1)
        self.cb_order21 = self._mk_order_row(g_ord, 0, "2F1+F2 (谐波)", "ORD21")
        self.cb_order12 = self._mk_order_row(g_ord, 1, "F1+2F2 (谐波)", "ORD12")
        self.cb_order11 = self._mk_order_row(g_ord, 2, "F1+F2  (谐波)", "ORD11")
        self.cb_orderdc = self._mk_order_row(g_ord, 3, "DC (无混频)",   "ORDDC")
        # 便捷功能: "全部统一为 ▼" → 一键把 4 个下拉框设为相同值并立即下发
        lbl_quick = QLabel("快捷统一")
        lbl_quick.setStyleSheet("font-size: 10pt; color: #f9a;")
        lbl_quick.setFixedWidth(95)
        g_ord.addWidget(lbl_quick, 4, 0)
        self.cb_order_all = QComboBox()
        self.cb_order_all.addItem("— 选择 —",        0)
        self.cb_order_all.addItem("1 阶  (6 dB/oct)",  1)
        self.cb_order_all.addItem("2 阶  (12 dB/oct)", 2)
        self.cb_order_all.addItem("3 阶  (18 dB/oct)", 3)
        self.cb_order_all.addItem("4 阶  (24 dB/oct)", 4)
        self.cb_order_all.setFixedHeight(30)
        self.cb_order_all.setFixedWidth(268)
        self.cb_order_all.setStyleSheet("font-size: 11pt; padding: 4px 8px;")
        self.cb_order_all.setToolTip("选一档后点 ▶ → 4 路全部设为相同阶数并立即下发")
        g_ord.addWidget(self.cb_order_all, 4, 1, 1, 2)
        btn_apply_all = QPushButton("▶")
        btn_apply_all.setFixedSize(42, 30)
        btn_apply_all.setStyleSheet(
            "font-size: 11pt; font-weight: bold;"
            " background:#a36; color:#fff;")
        btn_apply_all.clicked.connect(self._on_apply_order_all)
        g_ord.addWidget(btn_apply_all, 4, 3)
        v.addWidget(gb_ord)

        gb_freq = QGroupBox("通道频率扫频起点 (Hz)")
        g_freq = QGridLayout(gb_freq)
        self._setup_normal_grid(g_freq)
        self.ed_f1 = self._mk_freq_row(g_freq, 0, "F1 起点", "50000", "FRQ2")
        self.ed_f2 = self._mk_freq_row(g_freq, 1, "F2 起点", "60000", "FRQ3")
        v.addWidget(gb_freq)

        # ★ 通道3 三路开环锁相 ref_freq
        #   两种模式:
        #     自动: 三路 ref_freq 由 F1/F2 (上面的"通道频率扫频起点") 自动算出
        #            2F1+F2  /  F1+2F2  /  F1+F2 — 输入框变只读, 跟随 F1/F2 实时刷新
        #     手动: 三路 ref_freq 独立编辑, 不受 F1/F2 影响 (例如锁单一频点测试)
        #   恢复 PLL 后, "自动" 应改为跟随 pll_freq_ch1_hz / pll_freq_ch2_hz, 这一行在
        #   on_frame 里加一个补丁即可.
        gb_ref = QGroupBox("通道3 锁相参考频率 (Hz)")
        gb_ref.setToolTip(
            "自动: 三路 ref_freq = (2F1+F2 / F1+2F2 / F1+F2), 跟随上面 F1/F2 输入框实时刷新.\n"
            "手动: 三路 ref_freq 独立指定, 可任意锁一个频点 (例如做单频谐波灵敏度扫描).\n"
            "默认值 (自动 / 50k+60k) = 160 / 170 / 110 kHz.\n"
            "PLL 恢复后, 自动模式可改为跟随实时锁定的 pll_freq_ch1/ch2."
        )
        gb_ref_v = QVBoxLayout(gb_ref)

        # 模式切换行
        mode_h = QHBoxLayout()
        mode_h.addWidget(QLabel("模式:"))
        self.rb_ref_auto = QRadioButton("自动 (= F1/F2 组合频率)")
        self.rb_ref_man  = QRadioButton("手动")
        self.rb_ref_auto.setChecked(True)
        mode_h.addWidget(self.rb_ref_auto)
        mode_h.addWidget(self.rb_ref_man)
        mode_h.addStretch()
        gb_ref_v.addLayout(mode_h)

        # 三路输入框
        g_ref = QGridLayout()
        self._setup_normal_grid(g_ref)
        self.ed_fr21 = self._mk_freq_row(g_ref, 0, "2F1+F2", "160000", "FRQ21")
        self.ed_fr12 = self._mk_freq_row(g_ref, 1, "F1+2F2", "170000", "FRQ12")
        self.ed_fr11 = self._mk_freq_row(g_ref, 2, "F1+F2 ", "110000", "FRQ11")
        gb_ref_v.addLayout(g_ref)

        v.addWidget(gb_ref)

        # 信号连接 (放在所有控件创建完成后):
        #  - F1/F2 编辑时, 若是自动模式, 自动刷新三路 ref_freq
        #  - 切换模式时, 联动 readOnly 状态和样式
        self.rb_ref_auto.toggled.connect(self._on_ref_mode_toggled)
        self.ed_f1.textChanged.connect(self._on_f1f2_text_changed)
        self.ed_f2.textChanged.connect(self._on_f1f2_text_changed)
        # 上电初始化为"自动模式"对应的视觉/数据状态
        self._on_ref_mode_toggled(True)

        gb_phs = QGroupBox("相位偏移 (FRQ2 通道)")
        g_phs = QGridLayout(gb_phs)
        self._setup_normal_grid(g_phs)
        self.ed_phs = self._mk_param_row(g_phs, 0, "PHAS", "0", "PHAS")
        v.addWidget(gb_phs)

        gb_lock = QGroupBox("PLL 锁定阈值 (按信号强度调)")
        gb_lock.setToolTip(
            "信号强 (≥25%满量程) → 800000 / 3000000\n"
            "中等 / 不知道       → 100000 / 300000  (默认)\n"
            "信号弱 (<5%满量程)   → 20000  / 50000\n"
            "若锁出的频率一直在中心频率附近抖动, 通常是阈值太大, 请调小."
        )
        g_lock = QGridLayout(gb_lock)
        self._setup_normal_grid(g_lock)
        self.ed_swy = self._mk_param_row(g_lock, 0, "SWEEP_Y", "100000", "LOCKSWY")
        self.ed_thx = self._mk_param_row(g_lock, 1, "LOCK_X",  "300000", "LOCKTHX")
        v.addWidget(gb_lock)

        btn_send_all = QPushButton("⟹ 一键下发所有参数")
        btn_send_all.setStyleSheet("background:#3a5; color:white; font-weight:bold; padding:6px;")
        btn_send_all.clicked.connect(self.on_send_all_clicked)
        v.addWidget(btn_send_all)

        # 调试: 打印当前帧的全部诊断信息 (用于定位 PLL 是否真锁定 / 解析是否对齐)
        btn_diag = QPushButton("🔍 打印当前帧诊断")
        btn_diag.setStyleSheet("background:#356; color:white; padding:5px;")
        btn_diag.clicked.connect(self.on_diag_clicked)
        v.addWidget(btn_diag)

        v.addWidget(QLabel("日志"))
        self.log_view = QPlainTextEdit()
        self.log_view.setReadOnly(True)
        self.log_view.setMaximumBlockCount(500)
        self.log_view.setFont(QFont("Consolas", 8))
        v.addWidget(self.log_view, 1)

        return panel

    def _mk_param_row(self, grid, row, label, default, cmd):
        """普通整数参数行: [Label] [LineEdit] [▶].
        ★ 全部 setFixedWidth, 严格控制布局, 不依赖 grid stretch.
        """
        lbl = QLabel(label)
        lbl.setStyleSheet("font-size: 10pt;")
        lbl.setFixedWidth(95)
        grid.addWidget(lbl, row, 0)

        ed = QLineEdit(default)
        ed.setStyleSheet("font-size: 11pt; padding: 4px 8px;")
        ed.setAlignment(Qt.AlignCenter)
        ed.setFixedWidth(268)
        ed.setFixedHeight(30)
        grid.addWidget(ed, row, 1)

        btn = QPushButton("▶")
        btn.setFixedSize(42, 30)
        btn.setStyleSheet("font-size: 11pt; font-weight: bold;")
        btn.clicked.connect(lambda: self._send_int_cmd(cmd, ed.text()))
        grid.addWidget(btn, row, 2)
        return ed

    def _mk_tau_row(self, grid, row, label, default, cmd):
        """专用于 TAU 参数: 比 _mk_param_row 多一个实时 -3dB 截止频率提示标签.
        布局:  [Label]  [LineEdit]  [fc ≈ XXX Hz]  [▶]
        ★ 直接给每个控件 setFixedWidth, 不依赖 grid 的 columnMinimumWidth
          (后者在窗口 resize 时可能被 Qt 偷空间).
        ★ 点击 ▶ 按钮后, 整行 (Label/LineEdit/fc/Btn) 短暂高亮, 给视觉反馈.
        """
        lbl = QLabel(label)
        lbl.setStyleSheet("font-size: 10pt;")
        lbl.setFixedWidth(95)
        grid.addWidget(lbl, row, 0)

        ed = QLineEdit(default)
        ed.setStyleSheet("font-size: 12pt; padding: 4px 6px;")
        ed.setAlignment(Qt.AlignCenter)
        ed.setFixedWidth(115)             # ★ 硬下限, 保证 2-3 位数字清晰显示
        ed.setFixedHeight(30)
        ed.setToolTip(
            f"k = {TAU_MIN} ~ {TAU_MAX} 整数.\n"
            "α = 2^-k, IIR 一阶 EMA 系数.\n"
            f"fs = {IIR_FS_HZ/1e6:.0f} MHz (CIC 降采样后)."
        )
        grid.addWidget(ed, row, 1)

        fc_lbl = QLabel("")
        fc_lbl.setStyleSheet(
            "color: #4a8; font-family: Consolas, monospace; font-size: 10pt;")
        fc_lbl.setFixedWidth(145)         # ★ fc 标签也固定, 不再 stretch 抢空间
        grid.addWidget(fc_lbl, row, 2)

        btn = QPushButton("▶")
        btn.setFixedSize(42, 30)
        btn.setStyleSheet("font-size: 11pt; font-weight: bold;")
        btn.clicked.connect(lambda: (
            self._send_int_cmd(cmd, ed.text()),
            self._flash_row(lbl, ed, btn, fc_lbl=fc_lbl),
        ))
        grid.addWidget(btn, row, 3)

        def _refresh_fc():
            text, ok = tau_to_fc_label(ed.text())
            fc_lbl.setText(text)
            if ok:
                fc_lbl.setStyleSheet(
                    "color: #4a8; font-family: Consolas, monospace;"
                    " font-size: 10pt;")
            else:
                fc_lbl.setStyleSheet(
                    "color: #c33; font-family: Consolas, monospace;"
                    " font-size: 10pt; font-weight: bold;")

        ed.textChanged.connect(_refresh_fc)
        _refresh_fc()
        return ed

    def _mk_freq_row(self, grid, row, label, default, cmd):
        """频率参数行: [Label] [LineEdit] [▶].
        ★ 全部 setFixedWidth, 严格控制布局, 不依赖 grid stretch.
        """
        lbl = QLabel(label)
        lbl.setStyleSheet("font-size: 10pt;")
        lbl.setFixedWidth(95)
        grid.addWidget(lbl, row, 0)

        ed = QLineEdit(default)
        ed.setStyleSheet("font-size: 11pt; padding: 4px 8px;")
        ed.setAlignment(Qt.AlignCenter)
        ed.setFixedWidth(268)
        ed.setFixedHeight(30)
        grid.addWidget(ed, row, 1)

        btn = QPushButton("▶")
        btn.setFixedSize(42, 30)
        btn.setStyleSheet("font-size: 11pt; font-weight: bold;")
        btn.clicked.connect(lambda: self._send_freq_cmd(cmd, ed.text()))
        grid.addWidget(btn, row, 2)
        return ed

    def _setup_normal_grid(self, grid):
        """对"普通参数组"的 QGridLayout 统一布局.
        所有控件用 fixed width (在 _mk_param_row/_mk_freq_row 里设),
        grid 末尾加一个虚拟"吸收列"消化富余空间, 避免被 stretch 偷宽度.
        """
        grid.setVerticalSpacing(6)
        grid.setHorizontalSpacing(8)
        grid.setContentsMargins(10, 12, 10, 8)
        grid.setColumnStretch(0, 0)
        grid.setColumnStretch(1, 0)
        grid.setColumnStretch(2, 0)
        grid.setColumnStretch(3, 1)   # 末尾虚拟吸收列

    def _mk_order_row(self, grid, row, label, cmd):
        """单路 IIR 阶数选择行: [Label] [1..4 阶 ▼] [▶].

        cmd: ORD21 / ORD12 / ORD11 / ORDDC
        默认值 1 阶 (6 dB/oct, 与原 iir_lpf_ema 行为等价).
        ★ 全部 setFixedWidth, 不依赖 grid stretch (避免 resize 时被偷空间).
        """
        lbl = QLabel(label)
        lbl.setStyleSheet("font-size: 10pt;")
        lbl.setFixedWidth(95)
        grid.addWidget(lbl, row, 0)

        cb = QComboBox()
        cb.addItem("1 阶  (6 dB/oct)",  1)
        cb.addItem("2 阶  (12 dB/oct)", 2)
        cb.addItem("3 阶  (18 dB/oct)", 3)
        cb.addItem("4 阶  (24 dB/oct)", 4)
        cb.setCurrentIndex(0)
        cb.setFixedHeight(30)
        cb.setFixedWidth(268)            # 等宽 = LineEdit(115) + 间距 + fc(145) - 调整
        cb.setStyleSheet("font-size: 11pt; padding: 4px 8px;")
        cb.setToolTip(
            f"{cmd}: 单路 IIR 阶数 1..4.\n"
            "每加一阶, 阻带斜率 +6 dB/oct, 建立时间 +1 × τ_单阶."
        )
        grid.addWidget(cb, row, 1, 1, 2)

        btn = QPushButton("▶")
        btn.setFixedSize(42, 30)
        btn.setStyleSheet("font-size: 11pt; font-weight: bold;")
        btn.clicked.connect(lambda: (
            self._send_order_one(cmd, cb),
            self._flash_row(lbl, cb, btn),
        ))
        grid.addWidget(btn, row, 3)
        # ★ 把同行 Label/Button 挂到 cb 上, 方便 "快捷统一" 一次闪烁 4 行
        cb._row_lbl = lbl
        cb._row_btn = btn
        return cb

    # --- 通道3 ref_freq 自动/手动模式切换 ---------------------------------
    # 设计目的:
    #   自动模式: 三路 ref_freq 是 F1/F2 的固定函数 (2F1+F2 / F1+2F2 / F1+F2),
    #            输入框置为只读 + 灰底, 防止用户误改. F1/F2 变化时实时刷新.
    #   手动模式: 三路 ref_freq 任意编辑, 适合做单频点扫描或对照实验.
    #
    # 实现细节:
    #   - 切换时, 若是切到"自动", 立刻用 F1/F2 重算一次写回输入框 (不会触发
    #     textChanged 递归, 因为我们没监听 ed_fr21/12/11 的 textChanged).
    #   - 若 F1/F2 输入非法 (例如空字符串), _update_ref_freqs_from_f1f2 不抛异常,
    #     保留三路输入框原值即可.

    REF_AUTO_STYLE = (
        "QLineEdit { background: #2a2a2a; color: #888; }"  # 只读时灰底淡字
    )
    REF_MAN_STYLE = ""  # 恢复默认 (跟主题走)

    def _on_ref_mode_toggled(self, is_auto: bool):
        """单选按钮切换. is_auto = rb_ref_auto.isChecked()"""
        for ed in (self.ed_fr21, self.ed_fr12, self.ed_fr11):
            ed.setReadOnly(is_auto)
            ed.setStyleSheet(self.REF_AUTO_STYLE if is_auto else self.REF_MAN_STYLE)
        if is_auto:
            self._update_ref_freqs_from_f1f2()

    def _on_f1f2_text_changed(self, _txt: str):
        """F1 或 F2 输入框内容变化时, 若处于自动模式就同步刷新三路 ref_freq."""
        if self.rb_ref_auto.isChecked():
            self._update_ref_freqs_from_f1f2()

    def _update_ref_freqs_from_f1f2(self):
        """读 ed_f1 / ed_f2, 算 2F1+F2 / F1+2F2 / F1+F2 并写回输入框."""
        try:
            f1 = float(self.ed_f1.text())
            f2 = float(self.ed_f2.text())
        except (ValueError, AttributeError):
            return  # 输入非法或控件尚未就绪, 静默跳过
        self.ed_fr21.setText(f"{2 * f1 + f2:.0f}")
        self.ed_fr12.setText(f"{f1 + 2 * f2:.0f}")
        self.ed_fr11.setText(f"{f1 + f2:.0f}")

    # ------------------------------------------------------------- 绘图区
    def _build_plot_area(self) -> QWidget:
        # 4 个独立绘图面板, 每个带自己的 header
        # 上左: 通道1 PLL 锁定频率 F1 随时间变化 + F1 锁定灯
        self.panel_ch1 = PlotPanel("通道1 PLL 锁定频率 F1(t)", freq_label="F1", y_label="频率 (Hz)")
        self.curve_freq_ch1 = self.panel_ch1.plot.plot(
            pen=pg.mkPen("#4af", width=PEN_W), name="f1_hz")

        # 上右: 通道2 PLL 锁定频率 F2 随时间变化 + F2 锁定灯
        self.panel_ch2 = PlotPanel("通道2 PLL 锁定频率 F2(t)", freq_label="F2", y_label="频率 (Hz)")
        self.curve_freq_ch2 = self.panel_ch2.plot.plot(
            pen=pg.mkPen("#fa6", width=PEN_W), name="f2_hz")

        # 下左: 通道3 谐波分量 + DC (★ 支持任意多条曲线同时显示)
        self.panel_ch3_har = PlotPanel("通道3 谐波分量 + DC", y_label="幅值")

        # ── 顶部控制栏: 信号 ▼   分量 ▼   [+ 添加]  [清空] ──
        har_ctrl_layout = QHBoxLayout()
        har_ctrl_layout.setContentsMargins(10, 0, 10, 0)
        har_ctrl_layout.setSpacing(6)

        self.cb_har_select = QComboBox()
        self.cb_har_select.addItems(["2F1+F2", "F1+2F2", "F1+F2", "DC"])
        self.cb_har_select.setMinimumWidth(90)
        self.cb_har_select.currentIndexChanged.connect(self._on_har_select_changed)

        self.cb_comp_select = QComboBox()
        self.cb_comp_select.addItems(["X (同相)", "Y (正交)", "R (幅值)", "Θ (相位)"])
        self.cb_comp_select.setMinimumWidth(110)

        self.btn_add_curve = QPushButton("+ 添加")
        self.btn_add_curve.setToolTip(
            "把当前 (信号 × 分量) 组合作为新曲线添加到图中.\n"
            "可以重复添加任意多条不同的曲线同时显示."
        )
        self.btn_add_curve.setStyleSheet(
            "QPushButton { background:#2a6; color:#fff; font-weight:bold; padding:3px 10px; }"
            "QPushButton:hover { background:#3b7; }"
        )
        self.btn_add_curve.clicked.connect(self._on_add_curve)

        self.btn_clear_curves = QPushButton("清空")
        self.btn_clear_curves.setToolTip("移除所有曲线")
        self.btn_clear_curves.setStyleSheet(
            "QPushButton { background:#633; color:#fff; padding:3px 10px; }"
            "QPushButton:hover { background:#844; }"
        )
        self.btn_clear_curves.clicked.connect(self._on_clear_curves)

        har_ctrl_layout.addWidget(QLabel("信号:"))
        har_ctrl_layout.addWidget(self.cb_har_select)
        har_ctrl_layout.addWidget(QLabel("分量:"))
        har_ctrl_layout.addWidget(self.cb_comp_select)
        har_ctrl_layout.addWidget(self.btn_add_curve)
        har_ctrl_layout.addWidget(self.btn_clear_curves)
        har_ctrl_layout.addStretch()
        self.panel_ch3_har.layout().insertLayout(1, har_ctrl_layout)

        # ── chip 行: 已添加曲线的标签 (颜色 · 名字 · × 删除) ──
        self.har_chips_host = QWidget()
        self.har_chips_layout = QHBoxLayout(self.har_chips_host)
        self.har_chips_layout.setContentsMargins(10, 0, 10, 0)
        self.har_chips_layout.setSpacing(4)
        self.har_chips_layout.addStretch()
        self.panel_ch3_har.layout().insertWidget(2, self.har_chips_host)

        # ── 实时值显示 (4 路同时显示, 与曲线选择无关) ──
        # 三路谐波: X / Y / R / Θ ;  DC 只有幅值. 电压 mV, 相位保留 3 位小数.
        VAL_STYLE = ("color:#ddd; background:#1a1a1a; padding:2px 6px;"
                     " font-family:Consolas, monospace; font-size:9pt;")
        VAL_DEFAULT = "X: ---.--- mV  Y: ---.--- mV  R: ---.--- mV  Θ: ---.---°"

        self.lbl_har_21 = QLabel(f"2F1+F2 │ {VAL_DEFAULT}")
        self.lbl_har_12 = QLabel(f"F1+2F2 │ {VAL_DEFAULT}")
        self.lbl_har_11 = QLabel(f"F1+F2  │ {VAL_DEFAULT}")
        self.lbl_har_dc = QLabel( "DC     │ ---.--- mV")
        for lbl in (self.lbl_har_21, self.lbl_har_12,
                    self.lbl_har_11, self.lbl_har_dc):
            lbl.setStyleSheet(VAL_STYLE)
            lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)

        har_val_grid = QGridLayout()
        har_val_grid.setContentsMargins(10, 0, 10, 2)
        har_val_grid.setHorizontalSpacing(8)
        har_val_grid.setVerticalSpacing(1)
        har_val_grid.addWidget(self.lbl_har_21, 0, 0)
        har_val_grid.addWidget(self.lbl_har_12, 0, 1)
        har_val_grid.addWidget(self.lbl_har_11, 1, 0)
        har_val_grid.addWidget(self.lbl_har_dc, 1, 1)
        self.panel_ch3_har.layout().insertLayout(3, har_val_grid)

        # ── 多曲线状态 ──
        # 每项: {"sig": str, "comp": str, "curve": PlotDataItem,
        #         "chip":  QWidget,  "color": "#rrggbb"}
        self.har_curves = []
        self._har_color_idx = 0

        # 初始默认添加一条 (2F1+F2, X) 以保持开机就有曲线显示
        self._add_har_curve("2F1+F2", "X (同相)")

        self._on_har_select_changed(0)  # 初始化下拉框联动 (DC ↔ 分量禁用)

        # 下右: 通道3 ADC 波形
        self.panel_ch3_adc = PlotPanel("通道3 输入波形", y_label="ADC")
        self.curve_adc_ch3 = self.panel_ch3_adc.plot.plot(
            pen=pg.mkPen("#9af", width=PEN_W), name="adc_ch3")

        # 2x2 网格布局
        wrap = QWidget()
        grid = QGridLayout(wrap)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setSpacing(4)
        grid.addWidget(self.panel_ch1, 0, 0)
        grid.addWidget(self.panel_ch2, 0, 1)
        grid.addWidget(self.panel_ch3_har, 1, 0)
        grid.addWidget(self.panel_ch3_adc, 1, 1)
        return wrap

    # ------------------------------------------------------------- 窗口尺寸
    def resizeEvent(self, event):
        """窗口大小变化 (包括最大化/还原) 时, 强制左侧参数面板保持固定宽度.

        ★ 原因: QSplitter 默认在窗口 resize 时按 stretchFactor 比例分配空间.
        如果直接用 setSizes([460, 1040]) + stretchFactor(0, 0), 窗口最大化后
        左侧仍会按 460/(460+1040)=30% 比例缩放, 在 1920px 屏幕上变成 ~574px,
        看似变大, 但若用户屏幕更窄则会被挤压. 这里直接固定左侧 = 480px,
        其余全部交给绘图区.
        """
        super().resizeEvent(event)
        if hasattr(self, "splitter"):
            total = self.centralWidget().width() if self.centralWidget() else self.width()
            left_w = getattr(self, "_left_panel_w", 460)
            if total > left_w + 200:
                self.splitter.setSizes([left_w, total - left_w])

    # ------------------------------------------------------------- 暗色主题
    def _set_dark_theme(self):
        self.setStyleSheet("""
            QWidget { background: #2a2a2a; color: #ddd; font-family: 'Microsoft YaHei UI'; font-size: 10pt; }
            QGroupBox { border: 1px solid #555; border-radius: 4px; margin-top: 10px; padding-top: 6px; }
            QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px; color: #4af; font-weight: bold; }
            /* ★ 高亮分组: 用于 "IIR 时间常数" 和 "IIR 阶数" 等高频调整的关键参数 */
            QGroupBox#gbHighlight {
                border: 2px solid #f80;
                border-radius: 6px;
                margin-top: 14px;
                padding-top: 10px;
                background: #2f2a26;
                font-size: 11pt;
            }
            QGroupBox#gbHighlight::title {
                subcontrol-origin: margin; left: 10px; padding: 0 8px;
                color: #ffaa44; font-weight: bold; font-size: 11pt;
            }
            QLineEdit { background: #1e1e1e; border: 1px solid #555; border-radius: 3px; padding: 3px; }
            QLineEdit:focus { border-color: #4af; }
            QPushButton { background: #444; border: 1px solid #555; border-radius: 3px; padding: 4px 10px; }
            QPushButton:hover { background: #555; }
            QPushButton:pressed { background: #333; }
            QPushButton:disabled { background: #2a2a2a; color: #666; }
            QComboBox { background: #1e1e1e; border: 1px solid #555; border-radius: 3px; padding: 3px; }
            QComboBox:on { border-color: #4af; }
            QPlainTextEdit { background: #111; color: #aea; border: 1px solid #444; }
            QStatusBar { background: #1e1e1e; color: #ccc; }
            QLabel { color: #ddd; }
        """)

    # ============================================================ 事件处理
    def _refresh_ports(self):
        ports = list_serial_ports()
        cur = self.port_combo.currentText()
        self.port_combo.clear()
        self.port_combo.addItems(ports if ports else ["(无可用端口)"])
        if cur in ports:
            self.port_combo.setCurrentText(cur)

    def on_connect_clicked(self):
        if self.dev.is_connected:
            self.dev.disconnect()
        else:
            port = self.port_combo.currentText()
            self.dev.connect(port)

    def on_conn_changed(self, connected: bool):
        if connected:
            self.btn_connect.setText("断开")
            self.btn_stream.setEnabled(True)
            self.lbl_status_conn.setText("● 已连接")
            self.lbl_status_conn.setStyleSheet("color: #5d5;")
        else:
            self.btn_connect.setText("连接")
            self.btn_stream.setEnabled(False)
            self.btn_record.setEnabled(False)
            self.btn_stream.setText("开始数据流")
            self.lbl_status_conn.setText("● 未连接")
            self.lbl_status_conn.setStyleSheet("color: #f55;")
            # 清掉锁定灯
            self.panel_ch1.header.update(0.0, False)
            self.panel_ch2.header.update(0.0, False)

    def on_stream_clicked(self):
        if self.dev.is_streaming:
            self.dev.stop_streaming()
            self.btn_stream.setText("开始数据流")
            self.btn_record.setEnabled(False)
            self._stop_recording()
        else:
            self.dev.start_streaming()
            self.btn_stream.setText("停止数据流")
            self.btn_record.setEnabled(True)
            self.frame_count = 0
            self._fps_t0 = time.time()
            for k in self.buf:
                self.buf[k].clear()
            self.t_buf.clear()

    def _send_int_cmd(self, cmd, val_str):
        try:
            v = int(val_str)
        except ValueError:
            self.on_log(f"[!] {cmd} 值非法: {val_str}")
            return
        self.dev.send_command(f"{cmd}:{v}")

    def _send_freq_cmd(self, cmd, hz_str):
        try:
            hz = float(hz_str)
        except ValueError:
            self.on_log(f"[!] {cmd} 频率非法: {hz_str}")
            return
        word = hz_to_freq_word(hz)
        self.dev.send_command(f"{cmd}:{word}")
        self.on_log(f"  ({hz:.3f} Hz → 频率字 {word})")

    # ------------------------------------------------------------------
    # 视觉反馈: 点击参数行 ▶ 按钮后, 整行高亮 ~ 450 ms 再恢复
    # ------------------------------------------------------------------
    def _flash_row(self, lbl, value_w, btn, fc_lbl=None):
        """让 (Label, LineEdit/ComboBox, Button[, fc Label]) 短暂高亮.

        - 首次闪烁时把当前 styleSheet 记到控件的 ``_orig_style`` 属性, 之后
          的闪烁都拿这个 "原始样式" 来恢复, 避免连击时高亮叠加 / 错位.
        - fc_lbl 是 TAU 行独有的实时截止频率提示, 也参与闪烁.
        """
        FLASH_MS = 450

        def _stash(w):
            if not hasattr(w, "_orig_style"):
                w._orig_style = w.styleSheet()
            return w._orig_style

        s_lbl = _stash(lbl)
        s_val = _stash(value_w)
        s_btn = _stash(btn)
        s_fc  = _stash(fc_lbl) if fc_lbl is not None else None

        lbl.setStyleSheet(
            s_lbl + " color:#ffd042; font-weight: bold;"
        )
        value_w.setStyleSheet(
            s_val +
            " border: 2px solid #ffd042; background:#3a2f1e; color:#ffd042;"
        )
        btn.setStyleSheet(
            s_btn + " background:#4caf50; color:#fff;"
        )
        if fc_lbl is not None:
            fc_lbl.setStyleSheet(
                s_fc + " color:#ffd042; font-weight: bold;"
            )

        def _restore():
            # 用控件还活着时再恢复; 直接读 _orig_style (避免闭包变量过期)
            try:
                lbl.setStyleSheet(lbl._orig_style)
                value_w.setStyleSheet(value_w._orig_style)
                btn.setStyleSheet(btn._orig_style)
                if fc_lbl is not None:
                    fc_lbl.setStyleSheet(fc_lbl._orig_style)
            except RuntimeError:
                pass  # 控件已被销毁

        QTimer.singleShot(FLASH_MS, _restore)

    def _send_order_one(self, cmd: str, cb: QComboBox):
        """下发单路 IIR 阶数命令 (ORD21 / ORD12 / ORD11 / ORDDC)."""
        order = cb.currentData()  # QVariant: 1..4
        try:
            order = int(order)
        except (TypeError, ValueError):
            order = 1
        if order < 1 or order > 4:
            order = 1
        self.dev.send_command(f"{cmd}:{order}")
        self.on_log(f"  ({cmd} = {order} 阶, {order*6} dB/oct)")

    def _on_apply_order_all(self):
        """快捷统一: 把所有 4 路 IIR 阶数设为相同值并下发."""
        order = self.cb_order_all.currentData()
        try:
            order = int(order)
        except (TypeError, ValueError):
            order = 0
        if order < 1 or order > 4:
            self.on_log("[!] 请先在快捷统一下拉框选择 1~4 阶")
            return
        # 同步 4 个独立下拉框的显示 (索引 = order - 1, 因为 addItem 顺序就是 1..4)
        for cb in (self.cb_order21, self.cb_order12, self.cb_order11, self.cb_orderdc):
            cb.setCurrentIndex(order - 1)
        # 立即逐个下发
        self._send_order_one("ORD21", self.cb_order21)
        self._send_order_one("ORD12", self.cb_order12)
        self._send_order_one("ORD11", self.cb_order11)
        self._send_order_one("ORDDC", self.cb_orderdc)
        # 视觉反馈: 4 行同时高亮一下
        for cb in (self.cb_order21, self.cb_order12, self.cb_order11, self.cb_orderdc):
            self._flash_row(cb._row_lbl, cb, cb._row_btn)

    def on_send_all_clicked(self):
        self._send_int_cmd("KP", self.ed_kp.text())
        self._send_int_cmd("KI", self.ed_ki.text())
        self._send_int_cmd("TAU1X",  self.ed_t1x.text())
        self._send_int_cmd("TAU1Y",  self.ed_t1y.text())
        self._send_int_cmd("TAU2X",  self.ed_t2x.text())
        self._send_int_cmd("TAU2Y",  self.ed_t2y.text())
        self._send_int_cmd("TAU21", self.ed_t21.text())
        self._send_int_cmd("TAU12", self.ed_t12.text())
        self._send_int_cmd("TAU11", self.ed_t11.text())
        self._send_int_cmd("TAUDC", self.ed_tdc.text())
        self._send_int_cmd("PHAS", self.ed_phs.text())
        self._send_freq_cmd("FRQ2", self.ed_f1.text())
        self._send_freq_cmd("FRQ3", self.ed_f2.text())
        # ★ 通道3 三路 ref_freq (PLL 注释期间手动下发)
        self._send_freq_cmd("FRQ21", self.ed_fr21.text())
        self._send_freq_cmd("FRQ12", self.ed_fr12.text())
        self._send_freq_cmd("FRQ11", self.ed_fr11.text())
        self._send_int_cmd("LOCKSWY", self.ed_swy.text())
        self._send_int_cmd("LOCKTHX", self.ed_thx.text())
        # ★ 通道3 4 路 IIR 阶数 (各路独立, 1..4 = 6/12/18/24 dB/oct)
        self._send_order_one("ORD21", self.cb_order21)
        self._send_order_one("ORD12", self.cb_order12)
        self._send_order_one("ORD11", self.cb_order11)
        self._send_order_one("ORDDC", self.cb_orderdc)

    def on_diag_clicked(self):
        """点击 [打印当前帧诊断] 按钮: 把最近一帧的全部解析结果 dump 到日志,
        用于定位 PLL 是否真锁定, 以及解析是否对齐."""
        d = self._last_frame
        if d is None:
            self.on_log("[!] 还没收到任何数据帧, 先 [开始数据流] 再点诊断")
            return
        # 计算最近 N 帧的频率统计 (锁定后越稳越好)
        N = 50
        f1_buf = list(self.buf["pll_freq_ch1_hz"])[-N:]
        f2_buf = list(self.buf["pll_freq_ch2_hz"])[-N:]
        import statistics
        def stat(buf):
            if len(buf) < 2:
                return ("--", "--")
            return (f"{statistics.mean(buf):.3f}",
                    f"{statistics.stdev(buf):.3f}")
        f1_mean, f1_std = stat(f1_buf)
        f2_mean, f2_std = stat(f2_buf)

        lines = [
            "─" * 56,
            f"[诊断] 帧序号 {self.frame_count}",
            "─── 锁定状态 ────────────────────────────",
            f"  ch1 LOCKED = {d['locked_ch1']}    ch2 LOCKED = {d['locked_ch2']}",
            f"  lock_flags raw = 0b{d['lock_flags']:02b}",
            "─── PLL 频率字 (raw 48-bit) ─────────────",
            f"  ch1 word = {d['pll_freq_ch1_word']:>15d}  → {d['pll_freq_ch1_hz']:.3f} Hz",
            f"  ch2 word = {d['pll_freq_ch2_word']:>15d}  → {d['pll_freq_ch2_hz']:.3f} Hz",
            f"  最近 {len(f1_buf)} 帧 F1 均值={f1_mean} Hz, σ={f1_std} Hz   (σ大=没锁/PI抖)",
            f"  最近 {len(f2_buf)} 帧 F2 均值={f2_mean} Hz, σ={f2_std} Hz",
            "─── 锁相 X/Y (28-bit, 锁定时 |X| 大, |Y|→0) ─",
            f"  ch1: X = {d['ch1_x']:>+12d}    Y = {d['ch1_y']:>+12d}",
            f"  ch2: X = {d['ch2_x']:>+12d}    Y = {d['ch2_y']:>+12d}",
            "─── ADC 原始 (锁定时应有相干信号) ────────",
            f"  adc_ch1 = {d['adc_ch1']:>+8d}   adc_ch2 = {d['adc_ch2']:>+8d}   adc_ch3 = {d['adc_ch3']:>+8d}",
            "─── 判读 ─────────────────────────────────",
        ]
        # 自动判读
        verdict = []
        if not d['locked_ch1']:
            verdict.append("  ✗ ch1 未锁定 → 看 |Y| 是否大 (找信号失败) 或 |X| 是否小 (信号弱)")
        else:
            try:
                std1 = float(f1_std)
                if std1 > 5.0:
                    verdict.append(f"  ⚠ ch1 已锁定但 σ={std1:.2f}Hz 偏大, PI 可能轻微振荡 (减小 KI)")
                elif std1 > 1.0:
                    verdict.append(f"  ✓ ch1 锁定, σ={std1:.2f}Hz, 正常")
                else:
                    verdict.append(f"  ✓ ch1 锁定稳定, σ={std1:.2f}Hz")
            except ValueError:
                pass
        if abs(d['ch1_y']) > abs(d['ch1_x']):
            verdict.append("  ⚠ |Y|>|X| 异常: 还在拍频中, PLL 没真锁 (PI 没拉动?)")
        if d['locked_ch1'] and abs(d['ch1_x']) < 100_000:
            verdict.append(f"  ⚠ 已锁定但 |X|={abs(d['ch1_x'])} < 100K, 接近噪声本底, 容易掉锁")
        lines += verdict if verdict else ["  (无明显异常)"]
        lines.append("─" * 56)
        for ln in lines:
            self.on_log(ln)

    def _on_har_select_changed(self, _index=0):
        """信号下拉框切换时, 若选了 DC 则禁用 X/Y/Θ 分量, 因为
        DC 只有"幅值"一种意义 (无 IQ 解调).
        """
        if not hasattr(self, "cb_har_select"):
            return
        is_dc = self.cb_har_select.currentText() == "DC"
        if is_dc:
            self.cb_comp_select.setCurrentIndex(2)   # R (幅值)
            self.cb_comp_select.setEnabled(False)
        else:
            self.cb_comp_select.setEnabled(True)

    # ───── 通道3 多曲线添加 / 删除 ──────────────────────────────
    def _on_add_curve(self):
        """点击 [+ 添加] 按钮: 把当前 (信号 × 分量) 添加为新曲线."""
        sig = self.cb_har_select.currentText()
        comp = self.cb_comp_select.currentText()
        self._add_har_curve(sig, comp)

    def _add_har_curve(self, sig: str, comp: str):
        """实际创建一条曲线 + 对应的 chip 标签. sig 是 ``2F1+F2 / F1+2F2 / F1+F2 / DC``,
        comp 是分量下拉框文字 (含括号), 例如 ``X (同相)``.
        """
        # 同名曲线只保留一条, 防止用户重复点 "+"
        for c in self.har_curves:
            if c["sig"] == sig and c["comp"] == comp:
                self.on_log(f"[i] 曲线已存在: {sig} · {comp}")
                return

        color = HAR_PALETTE[self._har_color_idx % len(HAR_PALETTE)]
        self._har_color_idx += 1
        name = f"{sig} · {comp.split(' ')[0]}"          # legend 里短名字
        curve = self.panel_ch3_har.plot.plot(
            pen=pg.mkPen(color, width=PEN_W),
            name=name,
        )
        chip = self._make_har_chip(color, name)

        item = {"sig": sig, "comp": comp, "curve": curve,
                "chip": chip, "color": color, "name": name}
        # 把 × 按钮的删除回调绑到这个 item
        chip.btn_x.clicked.connect(lambda _checked=False, it=item: self._remove_har_curve(it))
        self.har_curves.append(item)
        # 插到 stretch 之前
        self.har_chips_layout.insertWidget(self.har_chips_layout.count() - 1, chip)

    def _remove_har_curve(self, item):
        """从图和 chip 行里删除一条曲线."""
        try:
            self.panel_ch3_har.plot.removeItem(item["curve"])
        except Exception:
            pass
        # 同步从 legend 删除
        legend = self.panel_ch3_har.plot.plotItem.legend
        if legend is not None:
            try:
                legend.removeItem(item["curve"])
            except Exception:
                pass
        item["chip"].setParent(None)
        item["chip"].deleteLater()
        if item in self.har_curves:
            self.har_curves.remove(item)

    def _on_clear_curves(self):
        """清空全部曲线."""
        for item in list(self.har_curves):
            self._remove_har_curve(item)
        self._har_color_idx = 0   # 重置调色板, 下一次添加从绿色开始

    def _make_har_chip(self, color: str, name: str) -> QWidget:
        """构造一个 chip widget: [▇ 颜色块] [名字] [×].
        点击 × 触发删除 (回调由调用方在创建后 connect 上去).
        """
        chip = QWidget()
        h = QHBoxLayout(chip)
        h.setContentsMargins(6, 1, 4, 1)
        h.setSpacing(4)
        chip.setStyleSheet(
            "QWidget { background:#262626; border:1px solid #444; border-radius:8px; }"
            "QLabel  { background:transparent; border:none; }"
        )

        sw = QLabel("●")
        sw.setStyleSheet(f"color:{color}; font-size:13pt;")
        h.addWidget(sw)

        lbl = QLabel(name)
        lbl.setStyleSheet(
            "color:#ddd; font-family:Consolas; font-size:9pt; padding:1px 2px;")
        h.addWidget(lbl)

        btn_x = QPushButton("×")
        btn_x.setFixedSize(18, 18)
        btn_x.setCursor(Qt.PointingHandCursor)
        btn_x.setStyleSheet(
            "QPushButton { background:transparent; color:#aaa; border:none; "
            "font-weight:bold; font-size:12pt; }"
            "QPushButton:hover { color:#f55; }"
        )
        h.addWidget(btn_x)
        chip.btn_x = btn_x    # 方便外部 connect
        return chip

    # 信号 → (X 键, Y 键) 映射 (DC 没有 Y, 用 None 占位)
    _HAR_SIG_KEYS = {
        "2F1+F2": ("ch3_x_21", "ch3_y_21"),
        "F1+2F2": ("ch3_x_12", "ch3_y_12"),
        "F1+F2":  ("ch3_x_11", "ch3_y_11"),
        "DC":     ("ch3_dc",   None),
    }

    def _refresh_har_curves(self, t: np.ndarray):
        """遍历 self.har_curves, 把每条曲线的数据 setData 进去.
        Y 轴单位智能切换: 全是电压类 (X/Y/R) → "电压 (V)";
                          全是相位 (Θ)        → "相位 (°)";
                          混合                → "电压 (V) / 相位 (°)".
        """
        if not self.har_curves:
            # 没曲线: 把 plot 标签恢复成默认占位, 也不画东西
            self.panel_ch3_har.plot.setLabel("left", "幅值")
            return

        has_voltage = False
        has_phase   = False
        for it in self.har_curves:
            sig  = it["sig"]
            comp = it["comp"]
            kx, ky = self._HAR_SIG_KEYS[sig]

            arr_x = np.asarray(self.buf[kx], dtype=float) * V_PER_LSB
            if ky is None:
                arr_y = np.zeros_like(arr_x)
            else:
                arr_y = np.asarray(self.buf[ky], dtype=float) * V_PER_LSB

            if comp.startswith("X"):
                y_data = arr_x
                has_voltage = True
            elif comp.startswith("Y"):
                y_data = arr_y
                has_voltage = True
            elif comp.startswith("R"):
                y_data = np.sqrt(arr_x * arr_x + arr_y * arr_y)
                has_voltage = True
            else:  # Θ
                y_data = np.degrees(np.arctan2(arr_y, arr_x))
                has_phase = True

            it["curve"].setData(t, y_data)

        if has_voltage and has_phase:
            self.panel_ch3_har.plot.setLabel("left", "电压 (V) / 相位 (°)")
        elif has_phase:
            self.panel_ch3_har.plot.setLabel("left", "相位 (°)")
        else:
            self.panel_ch3_har.plot.setLabel("left", "电压 (V)")

    # 谐波 X/Y 数据键名映射 (顺序与 lbl_har_21/12/11 对应)
    _HAR_KEYS = (
        ("2F1+F2", "ch3_x_21", "ch3_y_21"),
        ("F1+2F2", "ch3_x_12", "ch3_y_12"),
        ("F1+F2 ", "ch3_x_11", "ch3_y_11"),
    )

    def _update_har_text(self, *_):
        """每一帧把 4 路 (3 谐波 + DC) 的实时值全部刷新.
        与下拉框选择无关 (下拉框只控制波形画哪一路).
        电压单位 mV, 相位保留 3 位小数.
        """
        d = self._last_frame
        if d is None:
            return

        # 电压换算用模块级常量 MV_PER_LSB (见文件顶部 G_TOTAL 推导, 默认 ≈ 2.758e-4 mV/LSB).
        # 如果实测发现 GUI 值偏差固定比例, 改文件顶部的 CALIB_K 即可.

        # 3 路谐波: 各自显示 X / Y / R / Θ
        for lbl, (name, kx, ky) in zip(
            (self.lbl_har_21, self.lbl_har_12, self.lbl_har_11),
            self._HAR_KEYS,
        ):
            x_mv = d.get(kx, 0) * MV_PER_LSB
            y_mv = d.get(ky, 0) * MV_PER_LSB
            r_mv = math.sqrt(x_mv * x_mv + y_mv * y_mv)
            theta_deg = math.degrees(math.atan2(y_mv, x_mv))
            lbl.setText(
                f"{name} │ X: {x_mv:>+10.3f} mV  Y: {y_mv:>+10.3f} mV  "
                f"R: {r_mv:>10.3f} mV  Θ: {theta_deg:>+8.3f}°"
            )

        # DC: 只有幅值
        dc_mv = d.get("ch3_dc", 0) * MV_PER_LSB
        self.lbl_har_dc.setText(f"DC     │ {dc_mv:>+10.3f} mV   (无 Y/Θ)")

    # ============================================================ 数据接收
    def on_frame(self, data: dict):
        self.frame_count += 1
        for k in FIELD_NAMES:
            self.buf[k].append(data[k])
        self.t_buf.append(data["timestamp"])

        # 更新 header 显示需要的标量
        self._latest_freq_ch1 = data.get("pll_freq_ch1_hz", 0.0)
        self._latest_freq_ch2 = data.get("pll_freq_ch2_hz", 0.0)
        self._latest_locked_ch1 = data.get("locked_ch1", False)
        self._latest_locked_ch2 = data.get("locked_ch2", False)

        # 保存最近一帧 (供 "打印当前帧诊断" 按钮使用)
        self._last_frame = data
        
        # 更新 4 路谐波/DC 实时文本 (与下拉框选择无关, 全部同时刷新)
        if hasattr(self, 'lbl_har_dc'):
            self._update_har_text()

        # 派生频率轨迹也存进缓冲, 用于上行两个频率曲线
        self.buf["pll_freq_ch1_hz"].append(self._latest_freq_ch1)
        self.buf["pll_freq_ch2_hz"].append(self._latest_freq_ch2)

        if self.csv_writer:
            try:
                self.csv_writer.writerow(
                    [data["timestamp"]] + [data[k] for k in FIELD_NAMES])
            except Exception as e:
                self.on_log(f"[!] CSV 写入失败: {e}")

    # ============================================================ 绘图刷新
    def refresh_plots(self):
        if not self.t_buf:
            return
        t = np.array(self.t_buf)
        t = t - t[-1]   # 显示成"距离最新一帧多久"

        # 上行: PLL 锁定频率随时间变化 (取代原 ADC 原始波形)
        self.curve_freq_ch1.setData(t, np.array(self.buf["pll_freq_ch1_hz"]))
        self.curve_freq_ch2.setData(t, np.array(self.buf["pll_freq_ch2_hz"]))

        # 上行 header 频率/锁定灯
        self.panel_ch1.header.update(self._latest_freq_ch1, self._latest_locked_ch1)
        self.panel_ch2.header.update(self._latest_freq_ch2, self._latest_locked_ch2)

        # 下左: 通道3 谐波 - 多曲线同时绘制
        self._refresh_har_curves(t)

        # 下右: 通道3 ADC 波形
        self.curve_adc_ch3.setData(t, np.array(self.buf["adc_ch3"]))

        # FPS
        now = time.time()
        if now - self._fps_t0 > 0.5:
            self._fps = self.frame_count / (now - self._fps_t0)
            self.frame_count = 0
            self._fps_t0 = now
        self.lbl_status_fps.setText(f"FPS: {self._fps:5.1f}")
        self.lbl_status_buf.setText(f"缓冲: {len(self.t_buf)}/{PLOT_BUF}")

    # ============================================================ CSV 录制
    def on_record_clicked(self):
        if self.csv_writer:
            self._stop_recording()
        else:
            path, _ = QFileDialog.getSaveFileName(
                self, "保存 CSV", f"lockin_{time.strftime('%Y%m%d_%H%M%S')}.csv",
                "CSV (*.csv)")
            if not path:
                return
            try:
                self.csv_file = open(path, "w", newline="", encoding="utf-8")
                self.csv_writer = csv.writer(self.csv_file)
                self.csv_writer.writerow(["timestamp"] + FIELD_NAMES)
                self.btn_record.setText("⏹ 停止录制")
                self.btn_record.setStyleSheet("background:#a33; color:white;")
                self.lbl_status_rec.setText(f"● 录制中: {path.split('/')[-1]}")
                self.lbl_status_rec.setStyleSheet("color:#f55;")
                self.on_log(f"[+] 开始录制: {path}")
            except Exception as e:
                self.on_log(f"[!] 打开 CSV 失败: {e}")

    def _stop_recording(self):
        if self.csv_file:
            self.csv_file.close()
        self.csv_writer = None
        self.csv_file = None
        self.btn_record.setText("录制 CSV")
        self.btn_record.setStyleSheet("")
        self.lbl_status_rec.setText("")

    # ============================================================ 日志
    def on_log(self, msg: str):
        ts = time.strftime("%H:%M:%S")
        self.log_view.appendPlainText(f"[{ts}] {msg}")

    def closeEvent(self, ev):
        try:
            self.dev.stop_streaming()
            self.dev.disconnect()
        except Exception:
            pass
        self._stop_recording()
        super().closeEvent(ev)
