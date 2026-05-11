"""
main_window.py
──────────────
PyQt5 主窗口 ── 商用锁相放大器风格 GUI

布局 (2x2):
┌────────────────────────────────┬────────────────────────────────┐
│ 通道1 PLL 锁定频率 F1(t)        │ 通道2 PLL 锁定频率 F2(t)        │
│ F1 = 1234.567 Hz  [🟢锁定]     │ F2 = 5678.901 Hz  [🟢锁定]     │
├────────────────────────────────┼────────────────────────────────┤
│ 通道3 谐波 (3X + DC)           │ 通道3 ADC 输入波形             │
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
    QGroupBox, QLabel, QLineEdit, QPushButton, QComboBox,
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

# CIC 降采样后 IIR 实际工作的采样率 (Hz). 与 lock_in_amp.v 中
# cic_compiler_0 的 Fixed_Or_Initial_Rate=65 + 输入 65MHz 一致 → 1 MHz
IIR_FS_HZ = 1_000_000

TAU_MIN = 0
TAU_MAX = 31              # shift_k 是 5bit, 硬件支持上限


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
        splitter.setSizes([320, 1180])

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
        panel.setMaximumWidth(330)
        v = QVBoxLayout(panel)
        v.setSpacing(6)

        gb_pll = QGroupBox("PLL 锁相环参数")
        g_pll = QGridLayout(gb_pll)
        self.ed_kp = self._mk_param_row(g_pll, 0, "KP", "500", "KP")
        self.ed_ki = self._mk_param_row(g_pll, 1, "KI", "50", "KI")
        v.addWidget(gb_pll)

        gb_tau = QGroupBox(f"IIR 滤波时间常数  (k = {TAU_MIN} ~ {TAU_MAX}, fs = {IIR_FS_HZ/1e6:.0f} MHz)")
        gb_tau.setToolTip(
            "k 是 IIR 一阶 EMA 的位移量 (shift_k), 滤波器系数 α = 2^-k.\n"
            f"采样率 fs = {IIR_FS_HZ/1e6:.0f} MHz (CIC 降采样后).\n"
            "k 越大 → 截止频率 fc 越低, 滤波越慢, 噪声越小.\n"
            "k = 0 表示无滤波 (全通), k 范围 0~31."
        )
        g_tau = QGridLayout(gb_tau)
        self.ed_t1x  = self._mk_tau_row(g_tau, 0,  "CH1_X (PLL)",       "20", "TAU1X")
        self.ed_t1y  = self._mk_tau_row(g_tau, 1,  "CH1_Y (PLL)",       "8",  "TAU1Y")
        self.ed_t2x  = self._mk_tau_row(g_tau, 2,  "CH2_X (PLL)",       "20", "TAU2X")
        self.ed_t2y  = self._mk_tau_row(g_tau, 3,  "CH2_Y (PLL)",       "8",  "TAU2Y")
        self.ed_t21x = self._mk_tau_row(g_tau, 4,  "2F1+F2 X (谐波)",   "20", "TAU21X")
        self.ed_t21y = self._mk_tau_row(g_tau, 5,  "2F1+F2 Y (谐波)",   "20", "TAU21Y")
        self.ed_t12x = self._mk_tau_row(g_tau, 6,  "F1+2F2 X (谐波)",   "20", "TAU12X")
        self.ed_t12y = self._mk_tau_row(g_tau, 7,  "F1+2F2 Y (谐波)",   "20", "TAU12Y")
        self.ed_t11x = self._mk_tau_row(g_tau, 8,  "F1+F2  X (谐波)",   "20", "TAU11X")
        self.ed_t11y = self._mk_tau_row(g_tau, 9,  "F1+F2  Y (谐波)",   "20", "TAU11Y")
        self.ed_tdc  = self._mk_tau_row(g_tau, 10, "DC (无混频)",       "20", "TAUDC")
        v.addWidget(gb_tau)

        gb_freq = QGroupBox("通道频率扫频起点 (Hz)")
        g_freq = QGridLayout(gb_freq)
        self.ed_f1 = self._mk_freq_row(g_freq, 0, "F1 起点", "50000", "FRQ2")
        self.ed_f2 = self._mk_freq_row(g_freq, 1, "F2 起点", "60000", "FRQ3")
        v.addWidget(gb_freq)

        gb_phs = QGroupBox("相位偏移 (FRQ2 通道)")
        g_phs = QGridLayout(gb_phs)
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
        grid.addWidget(QLabel(label), row, 0)
        ed = QLineEdit(default)
        ed.setMaximumWidth(120)
        grid.addWidget(ed, row, 1)
        btn = QPushButton("▶")
        btn.setMaximumWidth(28)
        btn.clicked.connect(lambda: self._send_int_cmd(cmd, ed.text()))
        grid.addWidget(btn, row, 2)
        return ed

    def _mk_tau_row(self, grid, row, label, default, cmd):
        """专用于 TAU 参数: 比 _mk_param_row 多一个实时 -3dB 截止频率提示标签.
        布局:  [Label]  [LineEdit]  [fc ≈ XXX Hz]  [▶]
        """
        grid.addWidget(QLabel(label), row, 0)
        ed = QLineEdit(default)
        ed.setMaximumWidth(60)
        ed.setToolTip(
            f"k = {TAU_MIN} ~ {TAU_MAX} 整数.\n"
            "α = 2^-k, IIR 一阶 EMA 系数.\n"
            f"fs = {IIR_FS_HZ/1e6:.0f} MHz (CIC 降采样后)."
        )
        grid.addWidget(ed, row, 1)

        fc_lbl = QLabel("")
        fc_lbl.setMinimumWidth(140)
        fc_lbl.setStyleSheet("color: #4a8; font-family: Consolas, monospace;")
        grid.addWidget(fc_lbl, row, 2)

        btn = QPushButton("▶")
        btn.setMaximumWidth(28)
        btn.clicked.connect(lambda: self._send_int_cmd(cmd, ed.text()))
        grid.addWidget(btn, row, 3)

        def _refresh_fc():
            text, ok = tau_to_fc_label(ed.text())
            fc_lbl.setText(text)
            if ok:
                fc_lbl.setStyleSheet(
                    "color: #4a8; font-family: Consolas, monospace;")
            else:
                fc_lbl.setStyleSheet(
                    "color: #c33; font-family: Consolas, monospace;"
                    " font-weight: bold;")

        ed.textChanged.connect(_refresh_fc)
        _refresh_fc()
        return ed

    def _mk_freq_row(self, grid, row, label, default, cmd):
        grid.addWidget(QLabel(label), row, 0)
        ed = QLineEdit(default)
        ed.setMaximumWidth(120)
        grid.addWidget(ed, row, 1)
        btn = QPushButton("▶")
        btn.setMaximumWidth(28)
        btn.clicked.connect(lambda: self._send_freq_cmd(cmd, ed.text()))
        grid.addWidget(btn, row, 2)
        return ed

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

        # 下左: 通道3 谐波分量 + DC
        self.panel_ch3_har = PlotPanel("通道3 谐波分量 + DC", y_label="幅值")
        
        # 顶部加一个下拉框和值显示区域
        har_ctrl_layout = QHBoxLayout()
        har_ctrl_layout.setContentsMargins(10, 0, 10, 0)
        
        self.cb_har_select = QComboBox()
        self.cb_har_select.addItems(["2F1+F2", "F1+2F2", "F1+F2", "DC"])
        self.cb_har_select.setMinimumWidth(100)
        self.cb_har_select.currentIndexChanged.connect(self._on_har_select_changed)
        
        self.cb_comp_select = QComboBox()
        self.cb_comp_select.addItems(["X (同相)", "Y (正交)", "R (幅值)", "Θ (相位)"])
        self.cb_comp_select.setMinimumWidth(80)
        self.cb_comp_select.currentIndexChanged.connect(self._on_har_select_changed)
        
        har_ctrl_layout.addWidget(QLabel("信号:"))
        har_ctrl_layout.addWidget(self.cb_har_select)
        har_ctrl_layout.addWidget(QLabel("分量:"))
        har_ctrl_layout.addWidget(self.cb_comp_select)
        
        har_ctrl_layout.addStretch()

        # 把控制栏插入到 panel 的顶部
        self.panel_ch3_har.layout().insertLayout(1, har_ctrl_layout)

        # ── 实时值显示 (4 路同时显示, 与波形选择无关) ──
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
        self.panel_ch3_har.layout().insertLayout(2, har_val_grid)

        # 只保留一条曲线用于动态显示 (由下拉框控制画哪一路)
        self.curve_har = self.panel_ch3_har.plot.plot(
            pen=pg.mkPen("#5d5", width=PEN_W), name="Harmonic")

        self._on_har_select_changed(0)  # 初始化显示状态

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

    # ------------------------------------------------------------- 暗色主题
    def _set_dark_theme(self):
        self.setStyleSheet("""
            QWidget { background: #2a2a2a; color: #ddd; font-family: 'Microsoft YaHei UI'; font-size: 10pt; }
            QGroupBox { border: 1px solid #555; border-radius: 4px; margin-top: 10px; padding-top: 6px; }
            QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 5px; color: #4af; font-weight: bold; }
            QLineEdit { background: #1e1e1e; border: 1px solid #555; border-radius: 3px; padding: 3px; }
            QLineEdit:focus { border-color: #4af; }
            QPushButton { background: #444; border: 1px solid #555; border-radius: 3px; padding: 4px 10px; }
            QPushButton:hover { background: #555; }
            QPushButton:pressed { background: #333; }
            QPushButton:disabled { background: #2a2a2a; color: #666; }
            QComboBox { background: #1e1e1e; border: 1px solid #555; border-radius: 3px; padding: 3px; }
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

    def on_send_all_clicked(self):
        self._send_int_cmd("KP", self.ed_kp.text())
        self._send_int_cmd("KI", self.ed_ki.text())
        self._send_int_cmd("TAU1X",  self.ed_t1x.text())
        self._send_int_cmd("TAU1Y",  self.ed_t1y.text())
        self._send_int_cmd("TAU2X",  self.ed_t2x.text())
        self._send_int_cmd("TAU2Y",  self.ed_t2y.text())
        self._send_int_cmd("TAU21X", self.ed_t21x.text())
        self._send_int_cmd("TAU21Y", self.ed_t21y.text())
        self._send_int_cmd("TAU12X", self.ed_t12x.text())
        self._send_int_cmd("TAU12Y", self.ed_t12y.text())
        self._send_int_cmd("TAU11X", self.ed_t11x.text())
        self._send_int_cmd("TAU11Y", self.ed_t11y.text())
        self._send_int_cmd("TAUDC",  self.ed_tdc.text())
        self._send_int_cmd("PHAS", self.ed_phs.text())
        self._send_freq_cmd("FRQ2", self.ed_f1.text())
        self._send_freq_cmd("FRQ3", self.ed_f2.text())
        self._send_int_cmd("LOCKSWY", self.ed_swy.text())
        self._send_int_cmd("LOCKTHX", self.ed_thx.text())

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

    def _on_har_select_changed(self, index):
        """下拉框 (信号 / 分量) 切换时立即重绘一次, 否则要等下一个
        定时器周期 (~67 ms). 实时数值显示是 4 路同显, 与下拉框无关.
        """
        self.refresh_plots()

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

        # 1 LSB = 1 V / 2^24 = 0.0596 µV  →  转为 mV 系数
        MV_PER_LSB = 1000.0 / (1 << 24)

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

        # 下左: 通道3 谐波动态显示
        har_idx = self.cb_har_select.currentIndex()
        comp_idx = self.cb_comp_select.currentIndex()

        if har_idx == 0:
            arr_x = np.array(self.buf["ch3_x_21"])
            arr_y = np.array(self.buf["ch3_y_21"])
        elif har_idx == 1:
            arr_x = np.array(self.buf["ch3_x_12"])
            arr_y = np.array(self.buf["ch3_y_12"])
        elif har_idx == 2:
            arr_x = np.array(self.buf["ch3_x_11"])
            arr_y = np.array(self.buf["ch3_y_11"])
        else: # DC
            arr_x = np.array(self.buf["ch3_dc"])
            arr_y = np.zeros_like(arr_x)

        # 电压换算系数 (需要根据实际硬件标定, 这里暂定一个比例)
        # 假设 ADC 满量程是 1V, 14bit. 经过混频和 CIC 放大后, 需要一个系数转回电压
        VOLT_PER_LSB = 1.0 / (1 << 24) 

        arr_x_v = arr_x * VOLT_PER_LSB
        arr_y_v = arr_y * VOLT_PER_LSB

        if comp_idx == 0:   # X
            y_data = arr_x_v
            self.panel_ch3_har.plot.setLabel("left", "电压 (V)")
        elif comp_idx == 1: # Y
            y_data = arr_y_v
            self.panel_ch3_har.plot.setLabel("left", "电压 (V)")
        elif comp_idx == 2: # R
            y_data = np.sqrt(arr_x_v**2 + arr_y_v**2)
            self.panel_ch3_har.plot.setLabel("left", "幅值 (V)")
        else:               # Θ
            y_data = np.degrees(np.arctan2(arr_y_v, arr_x_v))
            self.panel_ch3_har.plot.setLabel("left", "相位 (°)")

        self.curve_har.setData(t, y_data)

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
