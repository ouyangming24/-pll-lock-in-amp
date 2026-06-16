"""
main_window.py
──────────────
PyQt5 主窗口 ── 商用锁相放大器风格 GUI

布局 (2x2):
┌────────────────────────────────┬────────────────────────────────┐
│ 通道1 PLL 锁定频率 F1(t)        │ 通道2 PLL 锁定频率 F2(t)        │
│ F1 = 1234.567 Hz  [🟢锁定]     │ F2 = 5678.901 Hz  [🟢锁定]     │
├────────────────────────────────┼────────────────────────────────┤
│ 解调值 (多曲线)                 │ 通道3 ADC 输入波形             │
│  信号▼ 分量▼ [+添加] [清空]    │                                │
│  [● 振荡器1·X ×] [● 直流·R ×]  │                                │
└────────────────────────────────┴────────────────────────────────┘

参数面板三色分组:
  橙 = 锁相环设置  |  绿 = 振荡器设置  |  蓝 = 信号发生器
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
    QSizePolicy, QCheckBox, QScrollArea,
)

from device import (
    LockinDevice, UdpLockinDevice, MockDevice, list_serial_ports,
    hz_to_freq_word, FIELD_NAMES, F_CLK,
)

# ============================================================================
# 配置
# ============================================================================
PLOT_BUF = 1000           # 每条曲线显示点数 (2000 → 1000, 减半绘图压力)
REFRESH_HZ = 15           # 绘图刷新率 (20 → 15, GUI 不再卡)
PEN_W = 1.2               # 线宽稍降, 配合关闭抗锯齿后视觉差别极小

# 振荡器 / 直流 — 用户界面显示名 (内部 buf 键 ch3_x_21 等不变)
OSC1_LBL = "振荡器1"
OSC2_LBL = "振荡器2"
OSC3_LBL = "振荡器3"
DC_LBL   = "直流"

# 振荡器 ADC 输入源 (与硬件 OSRC1/2/3 一致)
OSC_ADC_SRC_ITEMS = [("CH3", 0), ("CH4", 1), ("CH3-CH4", 2)]

# 通道3 解调多曲线绘图调色板 (循环使用, 8 色覆盖所有 4×4 组合都足够区分)
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

# ── 一键自动锁定 (CH1 / CH2) 参数 (可按需微调) ────────────────────────
# 捕获期 (acquire): 用稳健增益 + 软件 AGC 快速拉住, 容差大
AUTO_TAU_Y          = 7          # 捕获期环路鉴相 IIR (快而稳)
AUTO_TAU_X          = 16         # 捕获期幅值路 IIR (锁定判据)
AUTO_KP_BASE        = 500        # 在 AUTO_R_REF 基准幅度下的 KP
AUTO_KI_BASE        = 50         # 在 AUTO_R_REF 基准幅度下的 KI
AUTO_R_REF          = 2_000_000.0  # AGC 基准幅度 (LSB): KP = KP_BASE·R_REF/R
AUTO_KP_RANGE       = (20, 5000)   # AGC 后 KP 钳位范围
AUTO_KI_RANGE       = (2, 500)     # AGC 后 KI 钳位范围
# 保持期 (hold): 判稳后切到的"最终超稳参数".
#   KP=50, KI=5 → 保留积分项: 把稳态相位误差逼到 ~0 (相位读数 Θ 可重复/不随捕获落点漂),
#   并能跟踪信号慢漂; 频率读数靠大后置平滑 (AUTO_SMOOTH_N) 仍可达 mHz.
#   (旧值 KP=1/KI=0 频率读数最稳, 但 KI=0 留有随机静态相位误差, 谐波 Θ 不完全可重复.)
#   tau_x=20 (fc≈152 mHz, 幅度/判据路) / tau_y=15 (fc≈4.86 Hz, 进环误差路).
#   注意: KP/KI 在 FPGA 内两通道共享, 故为全局; tau 为本通道独立.
AUTO_FINAL_KP       = 50
AUTO_FINAL_KI       = 5
AUTO_FINAL_TAU_X    = 20
AUTO_FINAL_TAU_Y    = 15
AUTO_SMOOTH_N       = 400        # 稳定后把后置平滑 N 开到这么大 → mHz
AUTO_LOCK_TIMEOUT_S = 15.0       # 等"硬件锁定"超时
AUTO_VERIFY_TIMEOUT_S = 12.0     # 等"频率稳定"超时
AUTO_SETTLE_S       = 2.0        # AGC 后给环路重新稳定的时间
AUTO_STABLE_N       = 40         # 判稳: 连续多少帧
AUTO_STABLE_HZ      = 0.10       # 判稳: 最近 N 帧 (max-min) 阈值
AUTO_POLL_MS        = 100        # 状态机轮询周期

TAU_MIN = 0
TAU_MAX = 31              # shift_k 是 5bit, 硬件支持上限


# ============================================================================
# 电压换算 (锁相 dc_x / dc_y / dc_dc 码值 → 物理电压)
# ============================================================================
# 信号链:
#   V_in (峰值 V0) ──ADC──▶ 14bit signed (±2^13 对应 ±V_FS, V_FS 见下方实测标定)
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
ADC_FS_V = 9.75         # ADC 芯片侧"等效满量程"电压 (★ 实测标定, 不是面板量程!)
                        # ---------------------------------------------------
                        # 标定实验: 输入正弦 V₀ = 5V (峰值, 即面板 ±5V 满输入)
                        #   → ADC 码值峰值 ≈ ±4200 LSB (满码值 ±8192)
                        #   → ADC 芯片侧增益 = 4200 / 5 = 840 LSB/V
                        #   → 反推 V_FS = 2^13 / 840 ≈ 9.75 V
                        # 物理解释: 面板 ±5V 输入只占 ADC 动态范围的 ~50%,
                        # 模拟前端 (差分驱动 / Vref / 衰减比) 决定了这个比例.
                        # 这是硬件设计选择 (留 6 dB 余量), GUI 端只负责把
                        # 实际"码值/电压"映射用对.
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

# 实测标定系数 = (真实电压) / (GUI 当前显示值).
# K 拆成两组, 各自独立, 因为 X/Y/R (有混频) 和 DC (无混频) 走两条完全不同
# 的硬件路径, 标定偏差不一定相等.
#
# 标定记录:
#   2026-05-12  K_HAR: 用 Zurich Instruments 锁相测同一交流信号做交叉比对,
#                       本 GUI 比 Zurich 大 ~0.34% → × 0.9966 后一致.
#                       差异来源: ADC 模拟前端增益 / Vref / 电阻分压工艺误差.
#   2026-05-12  K_DC : 默认 1.0; 需要用万用表测 DC 输入后单独标定.
CALIB_K_HAR = 0.9966         # 谐波 X/Y/R 通路 (有混频)
CALIB_K_DC  = 1.0            # DC 通路 (无混频)

V_PER_LSB  = CALIB_K_HAR / G_TOTAL          # 码值 → V (X/Y/R 通路)
MV_PER_LSB = V_PER_LSB * 1000.0             # ≈ 5.38e-4 mV/LSB

# ----------------------------------------------------------------------------
# 通道3 DC 通路 (无混频, 无 DDS, 直接 ADC → CIC → IIR) 的端到端增益:
#       G_DC = (2^13 / V_FS) × G_cic
# 比 X/Y 通道 (有混频) 少了一个 (2^13 × 0.5) = 4096 倍因子.
# 所以 DC 通道必须用独立的 V_PER_LSB_DC, 否则显示会偏小 4096 倍.
G_DC = (1 << (ADC_BITS - 1)) / ADC_FS_V * CIC_GAIN_EFF       # ≈ 454 LSB/V

V_PER_LSB_DC  = CALIB_K_DC / G_DC          # 码值 → V (DC 通路, K_DC 独立)
MV_PER_LSB_DC = V_PER_LSB_DC * 1000.0      # ≈ 2.20 mV/LSB

# 幅值显示自动换单位: ≥1 V → V; ≥1 mV → mV; 否则 µV (均保留 4 位小数)
VOLT_DISPLAY_DECIMALS = 4


def auto_voltage_display_unit(abs_v: float) -> tuple[float, str]:
    """|V| → (伏特→显示单位的乘数, 基础单位 'V'/'mV'/'µV')."""
    if abs_v >= 1.0:
        return 1.0, "V"
    if abs_v >= 1e-3:
        return 1e3, "mV"
    return 1e6, "µV"


def auto_voltage_display_unit_for(*volts: float) -> tuple[float, str]:
    """多路幅值按最大 |V| 统一单位; 全零时默认 mV."""
    abs_max = max((abs(v) for v in volts), default=0.0)
    if abs_max == 0.0:
        return 1e3, "mV"
    return auto_voltage_display_unit(abs_max)


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
            self.lbl_freq.setText(f"{self.freq_label} = {freq_hz:>13.4f} Hz")
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
class FixedDecimalAxis(pg.AxisItem):
    """纵轴刻度强制保留固定小数位 (并关闭 SI 前缀/偏移), 用于频率图显示到 mHz."""
    def __init__(self, decimals: int = 3, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.decimals = decimals

    def tickStrings(self, values, scale, spacing):
        return [f"{v * scale:.{self.decimals}f}" for v in values]


class PlotPanel(QFrame):
    def __init__(self, title: str, freq_label: str | None = None,
                 y_label: str = "幅值", left_decimals: int | None = None):
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

        if left_decimals is not None:
            # 纵轴固定小数位 (频率图): 关掉 SI 前缀, 避免 60000.228 被显示成 60.000k
            _left_axis = FixedDecimalAxis(decimals=left_decimals, orientation="left")
            self.plot = pg.PlotWidget(axisItems={"left": _left_axis})
            _left_axis.enableAutoSIPrefix(False)
        else:
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
        self._udp_mode = udp_mode
        self._demo_mode = demo_mode
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

        # 运行时电压标定 (用户可在 GUI 上随时改). K 拆成两组独立:
        #   _calib_k_har → 只影响 X/Y/R (有混频) 通路 → _v_per_lsb / _mv_per_lsb
        #   _calib_k_dc  → 只影响 DC    (无混频) 通路 → _v_per_lsb_dc / _mv_per_lsb_dc
        # DC 通路换算因子比 X/Y 大 4096 倍 (因为 DC 通路没有 ×DDS×0.5 这一段增益).
        self._calib_k_har    = CALIB_K_HAR
        self._calib_k_dc     = CALIB_K_DC
        self._v_per_lsb      = CALIB_K_HAR / G_TOTAL
        self._mv_per_lsb     = self._v_per_lsb * 1000.0
        self._v_per_lsb_dc   = CALIB_K_DC / G_DC
        self._mv_per_lsb_dc  = self._v_per_lsb_dc * 1000.0

        # 运行时"时基(晶振)标定": k = 真实频率 / GUI 未标定显示频率 = 实际时钟 / 标称 65MHz
        #   显示: pll_freq_hz *= k ;  下发: word = hz_to_freq_word(hz / k)  (两者自洽)
        #   纯比例误差 (无截距), 故标定一个点即可; k = 1.0 表示不修正 (用理想 65 MHz)
        self._clk_cal = 1.0

        # 锁定频率"后置平滑"(读数精度, 与 PLL 环路带宽解耦):
        #   对已锁定的频率读数做独立滑动平均 → 环路可调快, 读数仍稳到 mHz.
        #   大跳变 (>jump Hz) 自动清空窗口 → 立刻跟随新频率, 不被旧值拖累.
        #   失锁时自动旁路 (显示瞬时值).
        self._freq_sm_enabled = True
        self._freq_sm_n       = 100      # 滑动窗口长度 (帧)
        self._freq_sm_jump    = 5.0      # 跳变阈值 (Hz): 超过则判为换频, 立即重置窗口
        self._freq_sm_buf     = [deque(maxlen=self._freq_sm_n),
                                 deque(maxlen=self._freq_sm_n)]

        # 一键自动锁定 (CH1) 状态机: idle → wait_lock → settle → verify → idle
        self._auto_state = "idle"
        self._auto_ch    = 1       # 当前自动锁定作用的通道 (1 或 2)
        self._auto_t0    = 0.0
        self._auto_timer = QTimer()
        self._auto_timer.timeout.connect(self._auto_step)

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
        if self._demo_mode:
            self.on_log("[+] 通信模式: DEMO (离线模拟)")
        elif self._udp_mode:
            self.on_log("[+] 通信模式: UDP 数据 + 串口命令 "
                        "(需 FPGA 已启用 eth_lockin_top; 当前工程默认未启用)")
        else:
            self.on_log("[+] 通信模式: 串口 (FT245 USB, 命令+数据; 需点「开始数据流」发 XYOUT)")

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
        param_panel = self._build_param_panel()
        # ★ 参数项较多, 用滚动区域包裹: 窗口高度不足时纵向滚动, 不再把各组压扁
        left = QScrollArea()
        left.setWidget(param_panel)
        left.setWidgetResizable(True)
        # 横向"按需": 万一内容仍超宽, 出现横向滚动条可滚动查看, 而不是被直接裁掉
        left.setHorizontalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        left.setFrameShape(QFrame.NoFrame)
        right = self._build_plot_area()

        LEFT_W = 512   # 参数面板 490 + 竖直滚动条(~17) + 余量, 保证 viewport ≥ 490 不裁切
        left.setMinimumWidth(LEFT_W)

        splitter = QSplitter(Qt.Horizontal)
        splitter.addWidget(left)
        splitter.addWidget(right)
        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        splitter.setChildrenCollapsible(False)
        splitter.setSizes([LEFT_W, 1040])
        self.splitter = splitter    # ★ 保存引用, resizeEvent 强制左侧宽度不缩水
        self._left_panel_w = LEFT_W # 与上面 setSizes 一致, resizeEvent 会引用此值

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
        panel.setMinimumWidth(450)
        panel.setSizePolicy(QSizePolicy.Preferred, QSizePolicy.Expanding)
        v = QVBoxLayout(panel)
        v.setSpacing(6)

        # ── 橙色: 锁相环设置 ─────────────────────────────────────
        gb_pll = QGroupBox("锁相环设置")
        gb_pll.setObjectName("gbPll")
        gb_pll.setToolTip(
            "PLL 环路增益、CH1/CH2 滤波、扫频起点、相位与锁定阈值、\n"
            "一键自动锁定、时基标定与频率读数平滑."
        )
        v_pll = QVBoxLayout(gb_pll)
        v_pll.setSpacing(6)

        g_pll = QGridLayout()
        self._setup_normal_grid(g_pll)
        self.ed_kp = self._mk_param_row(g_pll, 0, "KP", "500", "KP")
        self.ed_ki = self._mk_param_row(g_pll, 1, "KI", "50", "KI")
        w_pll = QWidget()
        w_pll.setLayout(g_pll)
        v_pll.addWidget(w_pll)

        gb_pll_tau = QGroupBox(
            f"PLL 通道滤波 TC  (k = {TAU_MIN} ~ {TAU_MAX}, fs = {IIR_FS_HZ/1e6:.0f} MHz)")
        gb_pll_tau.setToolTip(
            "CH1/CH2 解调 X/Y 的 IIR 时间常数.\n"
            "k 越大 → 截止越低、噪声越小、响应越慢."
        )
        g_pll_tau = QGridLayout(gb_pll_tau)
        g_pll_tau.setVerticalSpacing(6)
        g_pll_tau.setHorizontalSpacing(8)
        g_pll_tau.setContentsMargins(10, 14, 10, 10)
        g_pll_tau.setColumnStretch(0, 0)
        g_pll_tau.setColumnStretch(1, 0)
        g_pll_tau.setColumnStretch(2, 1)
        g_pll_tau.setColumnStretch(3, 0)
        self.ed_t1x = self._mk_tau_row(g_pll_tau, 0, "CH1_X", "20", "TAU1X")
        self.ed_t1y = self._mk_tau_row(g_pll_tau, 1, "CH1_Y", "8",  "TAU1Y")
        self.ed_t2x = self._mk_tau_row(g_pll_tau, 2, "CH2_X", "20", "TAU2X")
        self.ed_t2y = self._mk_tau_row(g_pll_tau, 3, "CH2_Y", "8",  "TAU2Y")
        v_pll.addWidget(gb_pll_tau)

        gb_freq = QGroupBox("扫频起点 F1 / F2 (Hz)")
        g_freq = QGridLayout(gb_freq)
        self._setup_normal_grid(g_freq)
        self.ed_f1 = self._mk_freq_row(g_freq, 0, "F1 起点", "50000", "FRQ2")
        self.ed_f2 = self._mk_freq_row(g_freq, 1, "F2 起点", "60000", "FRQ3")
        v_pll.addWidget(gb_freq)

        auto_tip = (
            "填好对应起点后点此:\n"
            "① 下发中心频率 + 稳健捕获参数 → ② 等待硬件锁定 →\n"
            "③ 按幅度自动整定 KP/KI (软件 AGC) → ④ 频率连续稳定后,\n"
            "自动切到最终参数 (KP=50, KI=5, tau_x=20, tau_y=15) + 大平滑,\n"
            "读数稳到 mHz. 过程中再次点击 = 取消.\n"
            "注意: KP/KI 与锁定阈值为双通道共享, 给某通道做自动锁定时\n"
            "捕获期会临时改变全局增益, 可能短暂扰动另一已锁通道."
        )
        auto_h = QHBoxLayout()
        self.btn_auto_lock = QPushButton("⚡ 一键自动锁定 CH1")
        self.btn_auto_lock.setStyleSheet(
            "background:#2a6cc0; color:#fff; font-weight:bold; padding:6px;")
        self.btn_auto_lock.setToolTip(auto_tip)
        self.btn_auto_lock.clicked.connect(lambda: self._on_auto_lock_clicked(1))
        self.btn_auto_lock2 = QPushButton("⚡ 一键自动锁定 CH2")
        self.btn_auto_lock2.setStyleSheet(
            "background:#2a6cc0; color:#fff; font-weight:bold; padding:6px;")
        self.btn_auto_lock2.setToolTip(auto_tip)
        self.btn_auto_lock2.clicked.connect(lambda: self._on_auto_lock_clicked(2))
        auto_h.addWidget(self.btn_auto_lock)
        auto_h.addWidget(self.btn_auto_lock2)
        v_pll.addLayout(auto_h)

        gb_phs = QGroupBox("相位偏移 (CH1 参考)")
        g_phs = QGridLayout(gb_phs)
        self._setup_normal_grid(g_phs)
        self.ed_phs = self._mk_param_row(g_phs, 0, "PHAS (°)", "0", "PHAS")
        v_pll.addWidget(gb_phs)

        gb_lock = QGroupBox("锁定阈值 (按信号强度)")
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
        v_pll.addWidget(gb_lock)

        v_pll.addWidget(self._build_clk_cal_group())
        v_pll.addWidget(self._build_freq_smooth_group())
        v.addWidget(gb_pll)

        # ── 绿色: 振荡器设置 ─────────────────────────────────────
        gb_osc = QGroupBox("振荡器设置")
        gb_osc.setObjectName("gbOsc")
        gb_osc.setToolTip(
            "通道3 三路相干振荡器与直流通路的 IIR 滤波、阶数与参考频率.\n"
            "自动模式: n×F1+m×F2 系数 (OSC1/2/3); 手动模式: 绝对频率 (FRQ21/12/11)."
        )
        v_osc = QVBoxLayout(gb_osc)
        v_osc.setSpacing(6)

        gb_tau = QGroupBox(
            f"解调滤波 TC  (k = {TAU_MIN} ~ {TAU_MAX}, fs = {IIR_FS_HZ/1e6:.0f} MHz)")
        gb_tau.setToolTip(
            "k 是 IIR 一阶 EMA 的位移量 (shift_k), 滤波器系数 α = 2^-k.\n"
            f"采样率 fs = {IIR_FS_HZ/1e6:.0f} MHz (CIC 降采样后).\n"
            "k 越大 → 截止频率 fc 越低, 滤波越慢, 噪声越小."
        )
        g_tau = QGridLayout(gb_tau)
        g_tau.setVerticalSpacing(6)
        g_tau.setHorizontalSpacing(8)
        g_tau.setContentsMargins(10, 14, 10, 10)
        g_tau.setColumnStretch(0, 0)
        g_tau.setColumnStretch(1, 0)
        g_tau.setColumnStretch(2, 1)
        g_tau.setColumnStretch(3, 0)
        self.ed_t21 = self._mk_tau_row(g_tau, 0, OSC1_LBL, "20", "TAU21")
        self.ed_t12 = self._mk_tau_row(g_tau, 1, OSC2_LBL, "20", "TAU12")
        self.ed_t11 = self._mk_tau_row(g_tau, 2, OSC3_LBL, "20", "TAU11")
        self.ed_tdc = self._mk_tau_row(g_tau, 3, DC_LBL,   "20", "TAUDC")
        v_osc.addWidget(gb_tau)

        gb_ord = QGroupBox("解调滤波阶数 (1..4 阶 = 6/12/18/24 dB/oct)")
        gb_ord.setToolTip(
            "每路 IIR 滤波器单独设置阶数 (3 路振荡器 + 直流共 4 个独立设置).\n"
            "实现: N 个相同 tau 的一阶 EMA 级联 (无过冲, 时域单调收敛)."
        )
        g_ord = QGridLayout(gb_ord)
        g_ord.setVerticalSpacing(6)
        g_ord.setHorizontalSpacing(8)
        g_ord.setContentsMargins(10, 14, 10, 10)
        g_ord.setColumnStretch(0, 0)
        g_ord.setColumnStretch(1, 0)
        g_ord.setColumnStretch(3, 0)
        g_ord.setColumnStretch(4, 1)
        self.cb_order21 = self._mk_order_row(g_ord, 0, OSC1_LBL, "ORD21")
        self.cb_order12 = self._mk_order_row(g_ord, 1, OSC2_LBL, "ORD12")
        self.cb_order11 = self._mk_order_row(g_ord, 2, OSC3_LBL, "ORD11")
        self.cb_orderdc = self._mk_order_row(g_ord, 3, DC_LBL,   "ORDDC")
        lbl_quick = QLabel("快捷统一")
        lbl_quick.setStyleSheet("font-size: 10pt; color: #8c8;")
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
            " background:#4a6; color:#fff;")
        btn_apply_all.clicked.connect(self._on_apply_order_all)
        g_ord.addWidget(btn_apply_all, 4, 3)
        v_osc.addWidget(gb_ord)

        v_osc.addWidget(self._build_ch3_osc_section())
        v.addWidget(gb_osc)

        # ── 蓝色: 信号发生器 ─────────────────────────────────────
        v.addWidget(self._build_dac_group())

        self.rb_ref_auto.toggled.connect(self._on_ref_mode_toggled)
        self.ed_f1.textChanged.connect(self._on_f1f2_text_changed)
        self.ed_f2.textChanged.connect(self._on_f1f2_text_changed)
        self._on_ref_mode_toggled(True)

        btn_send_all = QPushButton("⟹ 一键下发所有参数")
        btn_send_all.setStyleSheet("background:#3a5; color:white; font-weight:bold; padding:6px;")
        btn_send_all.clicked.connect(self.on_send_all_clicked)
        v.addWidget(btn_send_all)

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
        lbl.setFixedWidth(72)             # 容纳 "振荡器1" 等 CJK 标签
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
        # ★ 弹性: 占据剩余空间 (随面板变宽), 保证单位完整 + 按钮(col3)永远可见
        fc_lbl.setMinimumWidth(110)
        fc_lbl.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
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
        ed._send_btn = btn
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
    def _build_ch3_osc_section(self) -> QWidget:
        """通道3 三路振荡器参考频率: 自动=n×F1+m×F2 (OSC); 手动=绝对频率 (FRQ)."""
        w = QWidget()
        outer = QVBoxLayout(w)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(6)

        mode_h = QHBoxLayout()
        mode_h.addWidget(QLabel("参考模式:"))
        self.rb_ref_auto = QRadioButton("自动 (n·F1 + m·F2)")
        self.rb_ref_man  = QRadioButton("手动 (指定 Hz)")
        self.rb_ref_auto.setChecked(True)
        mode_h.addWidget(self.rb_ref_auto)
        mode_h.addWidget(self.rb_ref_man)
        mode_h.addStretch()
        outer.addLayout(mode_h)

        btn_all = QPushButton("▶ 下发全部振荡器系数")
        btn_all.setStyleSheet("font-size: 10pt; padding: 4px;")
        btn_all.clicked.connect(lambda: self._send_all_osc_coefs())
        self.btn_send_all_osc = btn_all
        outer.addWidget(btn_all)

        grid = QGridLayout()
        grid.setVerticalSpacing(6)
        grid.setHorizontalSpacing(6)
        grid.setContentsMargins(4, 4, 4, 4)
        grid.setColumnStretch(4, 1)

        self.ch3_oscs = []
        osc_defs = [
            (f"{OSC1_LBL}:", "OSC1", "OSRC1", "OHN1", "FRQ21", "160000", 2, 1),
            (f"{OSC2_LBL}:", "OSC2", "OSRC2", "OHN2", "FRQ12", "170000", 1, 2),
            (f"{OSC3_LBL}:", "OSC3", "OSRC3", "OHN3", "FRQ11", "110000", 1, 1),
        ]
        for row, (label, osc_cmd, osrc_cmd, ohn_cmd, frq_cmd, frq_def, n_def, m_def) in enumerate(osc_defs):
            lbl = QLabel(label)
            lbl.setStyleSheet("font-size: 10pt; font-weight: bold;")
            lbl.setFixedWidth(72)
            grid.addWidget(lbl, row, 0)

            btn = QPushButton("▶")
            btn.setFixedSize(36, 30)
            btn.setStyleSheet("font-size: 11pt; font-weight: bold;")
            grid.addWidget(btn, row, 1)

            cb_src = QComboBox()
            for text, val in OSC_ADC_SRC_ITEMS:
                cb_src.addItem(text, val)
            cb_src.setFixedWidth(88)
            cb_src.setFixedHeight(28)
            cb_src.setToolTip("该路振荡器解调所用的 ADC 输入源 (OSRC 命令)")
            grid.addWidget(cb_src, row, 2)

            ed_oh = QLineEdit("1")
            ed_oh.setFixedWidth(36)
            ed_oh.setFixedHeight(28)
            ed_oh.setAlignment(Qt.AlignCenter)
            ed_oh.setStyleSheet("font-size: 11pt; padding: 2px;")
            ed_oh.setToolTip("谐波阶数 N (OHN): 最终解调频率 = 基准频率 × N")

            harm_w = QWidget()
            hw = QHBoxLayout(harm_w)
            hw.setContentsMargins(0, 0, 0, 0)
            hw.setSpacing(2)
            hw.addWidget(QLabel("× N"))
            hw.addWidget(ed_oh)
            grid.addWidget(harm_w, row, 3)

            auto_w = QWidget()
            ah = QHBoxLayout(auto_w)
            ah.setContentsMargins(0, 0, 0, 0)
            ah.setSpacing(4)
            ed_n = QLineEdit(str(n_def))
            ed_m = QLineEdit(str(m_def))
            for ed in (ed_n, ed_m):
                ed.setFixedWidth(36)
                ed.setFixedHeight(28)
                ed.setAlignment(Qt.AlignCenter)
                ed.setStyleSheet("font-size: 11pt; padding: 2px;")
            ah.addWidget(ed_n)
            ah.addWidget(QLabel("× F1 +"))
            ah.addWidget(ed_m)
            ah.addWidget(QLabel("× F2"))
            ah.addStretch()
            grid.addWidget(auto_w, row, 4)

            ed_frq = QLineEdit(frq_def)
            ed_frq.setStyleSheet("font-size: 11pt; padding: 4px 8px;")
            ed_frq.setAlignment(Qt.AlignCenter)
            ed_frq.setFixedHeight(30)
            ed_frq.setToolTip("手动模式: 基准频率 (Hz), 最终 = 此值 × N")
            grid.addWidget(ed_frq, row, 4)

            lbl_hz = QLabel("≈ --- Hz")
            lbl_hz.setStyleSheet("font-size: 10pt; color: #8ad;")
            lbl_hz.setMinimumWidth(120)
            grid.addWidget(lbl_hz, row, 5)

            osc = {
                "ed_n": ed_n, "ed_m": ed_m, "ed_oh": ed_oh, "lbl_hz": lbl_hz,
                "auto_w": auto_w, "ed_frq": ed_frq, "btn": btn,
                "cb_src": cb_src,
                "osc_cmd": osc_cmd, "osrc_cmd": osrc_cmd,
                "ohn_cmd": ohn_cmd, "frq_cmd": frq_cmd,
            }
            cb_src.currentIndexChanged.connect(
                lambda _i, o=osc: self._auto_push_osc_src(o))
            ed_n.textChanged.connect(self._on_osc_coef_changed)
            ed_m.textChanged.connect(self._on_osc_coef_changed)
            ed_oh.textChanged.connect(self._on_osc_coef_changed)
            ed_n.editingFinished.connect(lambda o=osc: self._auto_push_osc(o))
            ed_m.editingFinished.connect(lambda o=osc: self._auto_push_osc(o))
            ed_oh.editingFinished.connect(lambda o=osc: self._auto_push_osc(o))
            ed_frq.editingFinished.connect(lambda o=osc: self._auto_push_osc(o))
            self.ch3_oscs.append(osc)
            btn.clicked.connect(lambda _c=False, o=osc: self._send_one_osc(o))

        outer.addLayout(grid)
        return w

    def _on_ref_mode_toggled(self, is_auto: bool):
        """切换自动(系数+OSC)/手动(频率+FRQ)面板."""
        auto = self.rb_ref_auto.isChecked()
        for osc in self.ch3_oscs:
            osc["auto_w"].setVisible(auto)
            osc["ed_frq"].setVisible(not auto)
            osc["btn"].setEnabled(True)
        self.btn_send_all_osc.setVisible(auto)
        self._update_osc_hz_display()
        if self.dev.is_connected:
            self._send_ref_mode()

    def _send_ref_mode(self, quiet: bool = False):
        """下发 REFMODE: 自动=1 (硬件 n·F1+m·F2), 手动=0 (FRQ21/12/11)."""
        auto = self.rb_ref_auto.isChecked()
        mode = 1 if auto else 0
        self.dev.send_command(f"REFMODE:{mode}")
        if quiet:
            return
        label = "硬件自动 (n·F1+m·F2)" if auto else "手动 (FRQ21/12/11)"
        self.on_log(f"[i] 通道3 ref 来源 = {label} (REFMODE:{mode})")

    def _pack_osc_val(self, n: int, m: int) -> int:
        return ((n & 0xFF) << 8) | (m & 0xFF)

    def _send_osc_src(self, osc: dict, quiet: bool = False):
        """下发单路振荡器 ADC 输入源 OSRCx: 0=CH3, 1=CH4, 2=CH3-CH4."""
        val = int(osc["cb_src"].currentData())
        if val not in (0, 1, 2):
            self.on_log(f"[!] {osc['osrc_cmd']} 非法: {val}")
            return
        self.dev.send_command(f"{osc['osrc_cmd']}:{val}")
        if not quiet:
            self.on_log(
                f"  {osc['osrc_cmd']}: {osc['cb_src'].currentText()} ({val})")

    def _auto_push_osc_src(self, osc: dict):
        if not getattr(self.dev, "is_connected", False):
            return
        self._send_osc_src(osc, quiet=True)

    def _send_all_osc_src(self, quiet: bool = False):
        for osc in self.ch3_oscs:
            self._send_osc_src(osc, quiet=True)
        if not quiet:
            self.on_log("[i] 已下发三路振荡器 ADC 输入源")

    def _parse_osc_harm(self, osc: dict) -> int | None:
        try:
            n = int(osc["ed_oh"].text())
        except ValueError:
            self.on_log(f"[!] {osc['ohn_cmd']} 非法")
            return None
        if not (1 <= n <= 255):
            self.on_log(f"[!] {osc['ohn_cmd']} 须 1..255")
            return None
        return n

    def _send_osc_harm(self, osc: dict, quiet: bool = False):
        """下发谐波阶数 OHNx: 最终 f_ref = f_base × N."""
        n = self._parse_osc_harm(osc)
        if n is None:
            return
        self.dev.send_command(f"{osc['ohn_cmd']}:{n}")
        if not quiet:
            self.on_log(f"  {osc['ohn_cmd']}: N={n}")

    def _send_all_osc_harm(self, quiet: bool = False):
        for osc in self.ch3_oscs:
            self._send_osc_harm(osc, quiet=True)
        if not quiet:
            self.on_log("[i] 已下发三路振荡器谐波阶数 N")

    def _send_one_osc(self, osc: dict, quiet: bool = False):
        """下发单路振荡器: ADC 源 + 谐波 N + 自动 OSC / 手动 FRQ."""
        self._send_osc_src(osc, quiet=True)
        self._send_osc_harm(osc, quiet=True)
        if self.rb_ref_auto.isChecked():
            try:
                n = int(osc["ed_n"].text())
                m = int(osc["ed_m"].text())
            except ValueError:
                self.on_log(f"[!] {osc['osc_cmd']} 系数非法")
                return
            if not (0 <= n <= 255 and 0 <= m <= 255):
                self.on_log(f"[!] {osc['osc_cmd']} 系数须 0..255")
                return
            val = self._pack_osc_val(n, m)
            self.dev.send_command(f"{osc['osc_cmd']}:{val}")
            if not quiet:
                self.on_log(f"  {osc['osc_cmd']}: n={n} m={m} (→ {val})")
        else:
            self._send_freq_cmd(osc["frq_cmd"], osc["ed_frq"].text())

    def _auto_push_osc(self, osc: dict):
        """编辑完成后自动下发该路: 自动模式发 OSCx 系数, 手动模式发 FRQxx 频率.
        (两种模式都覆盖, 避免"改了框没下发, 硬件还是旧值"的坑.)"""
        if not getattr(self.dev, "is_connected", False):
            return
        self._send_one_osc(osc)

    def _send_all_osc_coefs(self, quiet: bool = False):
        """自动模式: 下发三路 OSC 系数 + ADC 源 + REFMODE:1."""
        if not self.rb_ref_auto.isChecked():
            self.on_log("[!] 手动模式下请用各行 ▶ 发 FRQxx")
            return
        self._send_ref_mode(quiet=True)
        self._send_all_osc_src(quiet=True)
        for osc in self.ch3_oscs:
            self._send_one_osc(osc, quiet=True)
        if not quiet:
            parts = []
            for osc in self.ch3_oscs:
                parts.append(
                    f"{osc['osc_cmd']}={osc['ed_n'].text()}·F1+{osc['ed_m'].text()}·F2")
            self.on_log("[i] 已下发振荡器系数: " + ", ".join(parts))

    def _on_f1f2_text_changed(self, _txt: str):
        if self.rb_ref_auto.isChecked():
            self._update_osc_hz_display()

    def _on_osc_coef_changed(self, _txt: str = ""):
        if self.rb_ref_auto.isChecked():
            self._update_osc_hz_display()

    def _ref_source_f1f2(self):
        """返回 (f1, f2, src): 用于计算三路 ref 的基准频率.

        src = 'lock' 表示采用实测锁定频率, 'nom' 表示采用 F1/F2 起点标称值.
        仅在自动模式且对应通道锁定时优先用实测值; 否则回退标称值.
        输入非法 / 控件未就绪时返回 None.
        """
        try:
            f1 = float(self.ed_f1.text())
            f2 = float(self.ed_f2.text())
        except (ValueError, AttributeError):
            return None
        src = "nom"
        if getattr(self, "rb_ref_auto", None) is not None and self.rb_ref_auto.isChecked():
            if getattr(self, "_latest_locked_ch1", False) and self._latest_freq_ch1 > 0:
                f1 = self._latest_freq_ch1
                src = "lock"
            if getattr(self, "_latest_locked_ch2", False) and self._latest_freq_ch2 > 0:
                f2 = self._latest_freq_ch2
                src = "lock"
        return f1, f2, src

    def _update_osc_readback(self, d: dict):
        """诊断: 用数据帧回读的硬件实际参考频率刷新各振荡器旁的 lbl_hz.
        振荡器1→ref_hz_21, 振荡器2→ref_hz_12, 振荡器3→ref_hz_11.
        这是硬件真正在用的频率, 可直接核对 OSC/FRQ 命令是否真的下发生效."""
        if not getattr(self, "ch3_oscs", None):
            return
        keys = ("ref_hz_21", "ref_hz_12", "ref_hz_11")
        for osc, k in zip(self.ch3_oscs, keys):
            hz = d.get(k)
            if hz is None:
                continue
            osc["lbl_hz"].setText(f"硬件={hz:,.3f} Hz")

    def _osc_harm_factor(self, osc: dict) -> float:
        try:
            n = int(osc["ed_oh"].text())
            return float(n) if n >= 1 else 1.0
        except ValueError:
            return 1.0

    def _update_osc_hz_display(self):
        """按模式刷新各路估算/最终解调频率 (基准 × 谐波 N)."""
        if not getattr(self, "ch3_oscs", None):
            return
        auto = self.rb_ref_auto.isChecked()
        if auto:
            src = self._ref_source_f1f2()
            if src is None:
                return
            f1, f2, _ = src
            for osc in self.ch3_oscs:
                try:
                    n = int(osc["ed_n"].text())
                    m = int(osc["ed_m"].text())
                    hz = (n * f1 + m * f2) * self._osc_harm_factor(osc)
                    osc["lbl_hz"].setText(f"≈ {hz:.3f} Hz")
                except ValueError:
                    osc["lbl_hz"].setText("≈ --- Hz")
        else:
            for osc in self.ch3_oscs:
                try:
                    base = float(osc["ed_frq"].text())
                    hz = base * self._osc_harm_factor(osc)
                    osc["lbl_hz"].setText(f"≈ {hz:.3f} Hz")
                except ValueError:
                    osc["lbl_hz"].setText("≈ --- Hz")

    def _track_ref_freqs(self):
        """每帧刷新振荡器频率显示 (自动/手动均含 ×N)."""
        if getattr(self, "rb_ref_auto", None) is None:
            return
        self._update_osc_hz_display()

    # ------------------------------------------------- 时基(晶振)标定
    # 锁定频率读数有一个固定的 ppm 误差, 来自板载 50MHz 晶振相对理想值的偏差
    # (经 clk_wiz 倍频到 65MHz). 这是纯比例误差 (f_显 = f_真 / k, 过原点, 无截距),
    # 所以标定一个点即可确定 k = f_真 / f_显; 填多个点取平均更稳.
    #   修正后: 显示 pll_freq_hz *= k ; 下发 word = hz_to_freq_word(hz / k).
    def _build_clk_cal_group(self) -> QGroupBox:
        gb = QGroupBox("时基标定 (晶振 ppm 修正)")
        gb.setToolTip(
            "锁定频率的'基础误差'来自板载晶振相对理想 65MHz 的 ppm 偏差.\n"
            "纯比例误差 → 标定 1 个点即可, 多填几点取平均更稳.\n"
            "用法: '设定真值'填信号源真实频率, '实测显示'填 GUI 锁定稳定后的读数,\n"
            "点'计算并应用'即可; 也可直接在下方输入 ppm 手动设置.\n"
            "提示: 标定要等开机十几分钟、温度稳定后做, 用尽量准的信号源."
        )
        outer = QVBoxLayout(gb)
        outer.setContentsMargins(10, 12, 10, 8)
        outer.setSpacing(6)

        grid = QGridLayout()
        grid.setHorizontalSpacing(8)
        grid.setVerticalSpacing(4)
        h1 = QLabel("设定真值 (Hz)"); h1.setStyleSheet("font-size:9pt; color:#9bd;")
        h2 = QLabel("实测显示 (Hz)"); h2.setStyleSheet("font-size:9pt; color:#9bd;")
        grid.addWidget(h1, 0, 1)
        grid.addWidget(h2, 0, 2)

        self.ed_cal_true = []
        self.ed_cal_disp = []
        defaults_true = ["100000", "60000", "50000"]
        for i, dt in enumerate(defaults_true):
            lb = QLabel(f"点{i+1}"); lb.setFixedWidth(40); lb.setStyleSheet("font-size:10pt;")
            et = QLineEdit(dt); et.setFixedWidth(150); et.setAlignment(Qt.AlignCenter)
            ed = QLineEdit("");  ed.setFixedWidth(150); ed.setAlignment(Qt.AlignCenter)
            ed.setPlaceholderText("锁定稳定读数")
            grid.addWidget(lb, i + 1, 0)
            grid.addWidget(et, i + 1, 1)
            grid.addWidget(ed, i + 1, 2)
            self.ed_cal_true.append(et)
            self.ed_cal_disp.append(ed)
        outer.addLayout(grid)

        btn_h = QHBoxLayout()
        self.btn_cal_apply = QPushButton("计算并应用")
        self.btn_cal_apply.setStyleSheet(
            "background:#357; color:#fff; font-weight:bold; padding:4px 10px;")
        self.btn_cal_apply.clicked.connect(self._apply_clk_cal_from_points)
        self.btn_cal_reset = QPushButton("复位 (k=1)")
        self.btn_cal_reset.setStyleSheet("padding:4px 10px;")
        self.btn_cal_reset.clicked.connect(self._reset_clk_cal)
        btn_h.addWidget(self.btn_cal_apply)
        btn_h.addWidget(self.btn_cal_reset)
        btn_h.addStretch()
        outer.addLayout(btn_h)

        ppm_h = QHBoxLayout()
        ppm_h.addWidget(QLabel("手动 ppm:"))
        self.ed_cal_ppm = QLineEdit("0.000")
        self.ed_cal_ppm.setFixedWidth(90); self.ed_cal_ppm.setAlignment(Qt.AlignCenter)
        self.ed_cal_ppm.setToolTip(
            "时钟相对标称 65MHz 的偏差 ppm (负 = 实际偏慢 → 显示偏高). 回车或点 ▶ 应用.")
        self.ed_cal_ppm.returnPressed.connect(self._apply_clk_cal_from_ppm)
        btn_ppm = QPushButton("▶"); btn_ppm.setFixedWidth(36)
        btn_ppm.setStyleSheet("font-weight:bold;")
        btn_ppm.clicked.connect(self._apply_clk_cal_from_ppm)
        ppm_h.addWidget(self.ed_cal_ppm)
        ppm_h.addWidget(btn_ppm)
        ppm_h.addStretch()
        outer.addLayout(ppm_h)

        self.lbl_clk_cal = QLabel("当前: k = 1.0000000  (时钟偏差 +0.00 ppm)")
        self.lbl_clk_cal.setStyleSheet("font-size:9pt; color:#5d5;")
        outer.addWidget(self.lbl_clk_cal)
        return gb

    def _set_clk_cal(self, k: float, note: str = ""):
        """统一设置时基标定系数 k, 刷新 UI 与日志. 越界 (±10万ppm) 拒绝."""
        if not (0.9 <= k <= 1.1):
            self.on_log(f"[!] 时基标定 k={k:.7f} 超出合理范围 (0.9~1.1), 已忽略")
            return
        self._clk_cal = k
        ppm = (k - 1.0) * 1e6
        self.lbl_clk_cal.setText(f"当前: k = {k:.7f}  (时钟偏差 {ppm:+.2f} ppm)")
        if hasattr(self, "ed_cal_ppm"):
            self.ed_cal_ppm.setText(f"{ppm:.3f}")
        self.on_log(f"[i] 时基标定已应用: k={k:.7f} ({ppm:+.2f} ppm){(' ' + note) if note else ''}")

    def _apply_clk_cal_from_points(self):
        """读各标定点, 算 k = mean(真值 / 显示) 并应用. 只统计两栏都填了的行."""
        ks = []
        for et, ed in zip(self.ed_cal_true, self.ed_cal_disp):
            ts, ds = et.text().strip(), ed.text().strip()
            if not ts or not ds:
                continue
            try:
                tv, dv = float(ts), float(ds)
            except ValueError:
                self.on_log(f"[!] 标定点数值非法: '{ts}' / '{ds}', 跳过")
                continue
            if tv <= 0 or dv <= 0:
                continue
            ks.append(tv / dv)
        if not ks:
            self.on_log("[!] 没有有效标定点 (每点需同时填'设定真值'和'实测显示')")
            return
        self._set_clk_cal(sum(ks) / len(ks), note=f"(由 {len(ks)} 个点平均)")

    def _apply_clk_cal_from_ppm(self):
        """直接按手动输入的 ppm 设置 k = 1 + ppm·1e-6."""
        try:
            ppm = float(self.ed_cal_ppm.text().strip())
        except ValueError:
            self.on_log(f"[!] ppm 非法: '{self.ed_cal_ppm.text()}'")
            return
        self._set_clk_cal(1.0 + ppm * 1e-6, note="(手动 ppm)")

    def _reset_clk_cal(self):
        self._set_clk_cal(1.0, note="(复位, 不修正)")

    # ------------------------------------------- 锁定频率后置平滑 (读数精度)
    # 与 PLL 环路带宽解耦: 对"已锁定"的频率读数做独立滑动平均, 所以环路 / IIR
    # 可以调快 (快速锁定), 读数精度则靠这级平均做到 mHz. 关键是大跳变检测:
    # 当瞬时值偏离窗口均值超过阈值 (换频 / 大跳变), 立即清空窗口跟随新值,
    # 不被旧频率拖累 —— 这正是"大跳变也能快速稳定"的做法.
    def _build_freq_smooth_group(self) -> QGroupBox:
        gb = QGroupBox("锁定频率平滑 (读数精度)")
        gb.setToolTip(
            "对已锁定的频率读数做独立后置平均, 与 PLL 环路带宽解耦:\n"
            "→ 环路 / IIR 可以调快 (快速锁定), 读数仍能平均到 mHz 级.\n"
            "大跳变 (超过'跳变阈值') 会自动清空窗口、立即跟随新频率, 不被旧值拖累.\n"
            "失锁时自动旁路 (直接显示瞬时值)."
        )
        outer = QVBoxLayout(gb)
        outer.setContentsMargins(10, 12, 10, 8)
        outer.setSpacing(6)

        row1 = QHBoxLayout()
        self.cb_freq_sm = QCheckBox("启用")
        self.cb_freq_sm.setChecked(self._freq_sm_enabled)
        self.cb_freq_sm.toggled.connect(self._on_freq_sm_changed)
        row1.addWidget(self.cb_freq_sm)
        row1.addStretch()
        outer.addLayout(row1)

        grid = QGridLayout()
        grid.setHorizontalSpacing(8)
        grid.setVerticalSpacing(4)
        l1 = QLabel("平均点数 N"); l1.setFixedWidth(95); l1.setStyleSheet("font-size:10pt;")
        self.ed_freq_sm_n = QLineEdit(str(self._freq_sm_n))
        self.ed_freq_sm_n.setFixedWidth(110); self.ed_freq_sm_n.setAlignment(Qt.AlignCenter)
        self.ed_freq_sm_n.setToolTip("滑动窗口长度 (帧). 越大越稳、跟随越慢. 典型 50~300.")
        l2 = QLabel("跳变阈值(Hz)"); l2.setFixedWidth(95); l2.setStyleSheet("font-size:10pt;")
        self.ed_freq_sm_jump = QLineEdit(f"{self._freq_sm_jump:g}")
        self.ed_freq_sm_jump.setFixedWidth(110); self.ed_freq_sm_jump.setAlignment(Qt.AlignCenter)
        self.ed_freq_sm_jump.setToolTip(
            "瞬时值偏离窗口均值超过此值 → 判为换频 / 大跳变, 立即清空窗口跟随新值.\n"
            "设大: 抗噪强但换频跟随略慢; 设小: 换频跟随快但易被噪声触发重置.")
        grid.addWidget(l1, 0, 0); grid.addWidget(self.ed_freq_sm_n, 0, 1)
        grid.addWidget(l2, 1, 0); grid.addWidget(self.ed_freq_sm_jump, 1, 1)
        btn = QPushButton("应用")
        btn.setFixedWidth(60)
        btn.setStyleSheet("background:#357; color:#fff; font-weight:bold;")
        btn.clicked.connect(self._on_freq_sm_changed)
        grid.addWidget(btn, 0, 2, 2, 1)
        outer.addLayout(grid)
        return gb

    # ------------------------------------------- 信号发生器 (DAC904)
    # 三种工作模式 (DMOD):
    #   0 内部DDS : 频率 (DFRQ) / 相位 (DPHS) 由上位机指定, 独立信号源
    #   1 跟随CH1 : 输出频率 = CH1 PLL 锁定频率 (与外参考同频输出)
    #   2 跟随CH2 : 输出频率 = CH2 PLL 锁定频率
    # 频率字换算与锁相一致 (含时基标定 _clk_cal); 相位按 角度→48bit 相位字 换算.
    def _build_dac_group(self) -> QGroupBox:
        gb = QGroupBox("信号发生器")
        gb.setObjectName("gbDac")
        gb.setToolTip(
            "硬件: DAC904 (offset binary, 14bit), 采样时钟 = clk_65M.\n"
            "模式: 内部DDS = 自定义频率/相位独立信号源;\n"
            "      跟随CH1/CH2 = 输出与对应通道外参考锁定结果同频 (相位用'相位'微调).\n"
            "跟随模式下'频率'输入被硬件忽略 (由 PLL 锁定频率决定)."
        )
        outer = QVBoxLayout(gb)
        outer.setContentsMargins(10, 12, 10, 8)
        outer.setSpacing(6)

        # 模式行: 下拉 + ▶
        mode_h = QHBoxLayout()
        lbl_mode = QLabel("信号源"); lbl_mode.setFixedWidth(95); lbl_mode.setStyleSheet("font-size:10pt;")
        self.cb_dac_mode = QComboBox()
        self.cb_dac_mode.addItem("内部 DDS (自定义)", 0)
        self.cb_dac_mode.addItem("跟随 CH1 锁定频率", 1)
        self.cb_dac_mode.addItem("跟随 CH2 锁定频率", 2)
        self.cb_dac_mode.setFixedHeight(30)
        self.cb_dac_mode.setFixedWidth(268)
        self.cb_dac_mode.setStyleSheet("font-size: 11pt; padding: 4px 8px;")
        self.cb_dac_mode.currentIndexChanged.connect(self._on_dac_mode_changed)
        btn_mode = QPushButton("▶"); btn_mode.setFixedSize(42, 30)
        btn_mode.setStyleSheet("font-size: 11pt; font-weight: bold;")
        btn_mode.clicked.connect(self._send_dac_mode)
        mode_h.addWidget(lbl_mode); mode_h.addWidget(self.cb_dac_mode); mode_h.addWidget(btn_mode)
        mode_h.addStretch()
        outer.addLayout(mode_h)

        # 频率 / 相位行
        grid = QGridLayout()
        self._setup_normal_grid(grid)
        self.ed_dac_freq = self._mk_freq_row(grid, 0, "频率 (Hz)", "50000", "DFRQ")
        # 相位行: 单独做 (角度 → 相位字), 不走 _mk_freq_row
        lbl_ph = QLabel("相位 (°)"); lbl_ph.setFixedWidth(95); lbl_ph.setStyleSheet("font-size:10pt;")
        grid.addWidget(lbl_ph, 1, 0)
        self.ed_dac_phase = QLineEdit("0")
        self.ed_dac_phase.setStyleSheet("font-size: 11pt; padding: 4px 8px;")
        self.ed_dac_phase.setAlignment(Qt.AlignCenter)
        self.ed_dac_phase.setFixedWidth(268); self.ed_dac_phase.setFixedHeight(30)
        self.ed_dac_phase.setToolTip("0~360°, 内部换算为 48bit 相位字下发 (DPHS).")
        grid.addWidget(self.ed_dac_phase, 1, 1)
        btn_ph = QPushButton("▶"); btn_ph.setFixedSize(42, 30)
        btn_ph.setStyleSheet("font-size: 11pt; font-weight: bold;")
        btn_ph.clicked.connect(lambda: self._send_dac_phase(self.ed_dac_phase.text()))
        grid.addWidget(btn_ph, 1, 2)
        outer.addLayout(grid)

        self._on_dac_mode_changed()   # 初始化频率框可用状态
        return gb

    def _on_dac_mode_changed(self, *_):
        """跟随 CH1/CH2 模式下, 频率输入框置灰 (硬件忽略)."""
        if not hasattr(self, "ed_dac_freq"):
            return
        internal = (self.cb_dac_mode.currentData() == 0)
        self.ed_dac_freq.setEnabled(internal)
        self.ed_dac_freq.setToolTip(
            "内部DDS 输出频率 (Hz)." if internal
            else "跟随模式下此值被硬件忽略 (输出频率 = PLL 锁定频率).")

    def _send_dac_mode(self):
        mode = int(self.cb_dac_mode.currentData())
        self.dev.send_command(f"DMOD:{mode}")
        self.on_log(f"[i] 信号发生器模式 = {self.cb_dac_mode.currentText()} (DMOD:{mode})")

    def _send_dac_phase(self, deg_str):
        try:
            deg = float(deg_str)
        except ValueError:
            self.on_log(f"[!] DPHS 相位非法: {deg_str}")
            return
        word = int(round((deg % 360.0) / 360.0 * (1 << 48))) & ((1 << 48) - 1)
        self.dev.send_command(f"DPHS:{word}")
        self.on_log(f"  (DAC 相位 {deg:.3f}° → 相位字 {word})")

    def _smooth_freq(self, ch: int, raw: float, locked: bool) -> float:
        """对单通道锁定频率做滑动平均; 未锁/未启用/大跳变时旁路或重置窗口."""
        buf = self._freq_sm_buf[ch]
        if (not self._freq_sm_enabled) or (not locked) or raw <= 0:
            buf.clear()
            return raw
        if buf:
            m = sum(buf) / len(buf)
            if abs(raw - m) > self._freq_sm_jump:
                buf.clear()      # 换频 / 大跳变: 丢弃旧窗口, 立即跟随新频率
        buf.append(raw)
        return sum(buf) / len(buf)

    def _on_freq_sm_changed(self, *_):
        """应用平滑开关 / 窗口长度 / 跳变阈值."""
        self._freq_sm_enabled = self.cb_freq_sm.isChecked()
        try:
            n = int(float(self.ed_freq_sm_n.text().strip()))
        except ValueError:
            n = self._freq_sm_n
        n = max(1, min(5000, n))
        self.ed_freq_sm_n.setText(str(n))
        try:
            jump = float(self.ed_freq_sm_jump.text().strip())
        except ValueError:
            jump = self._freq_sm_jump
        if jump <= 0:
            jump = self._freq_sm_jump
        self.ed_freq_sm_jump.setText(f"{jump:g}")
        if n != self._freq_sm_n:
            self._freq_sm_n = n
            self._freq_sm_buf = [deque(self._freq_sm_buf[0], maxlen=n),
                                 deque(self._freq_sm_buf[1], maxlen=n)]
        self._freq_sm_jump = jump
        self.on_log(
            f"[i] 锁定频率平滑: {'开' if self._freq_sm_enabled else '关'}, "
            f"N={n}, 跳变阈值={jump:g} Hz")

    # ------------------------------------------- 一键自动锁定 (CH1 / CH2)
    # 流程 (非阻塞状态机, QTimer 每 100ms 推进一步, 同一时刻只跑一个通道):
    #   wait_lock : 下发中心频率+稳健捕获参数, 轮询硬件 is_locked
    #   settle    : 锁上后按幅度 R 软件 AGC 整定 KP/KI, 给环路重新稳定时间
    #   verify    : 等"最近 N 帧频率波动 < 阈值"判定真稳 → 切最终超稳参数 + 大平滑 → mHz
    #
    # 硬件约束: KP/KI 与锁定阈值在 FPGA 内两通道共享 (全局), 只有 IIR tau 与频率
    #   是分通道的. 所以给某通道做自动锁定时, 捕获期改的是"全局"增益, 会临时
    #   扰动另一已锁通道; 收尾时统一回到 KP=AUTO_FINAL_KP/KI=AUTO_FINAL_KI (两通道一致).
    def _auto_cfg(self, ch: int) -> dict:
        """返回通道相关的控件 / 帧字段 / 命令映射 (KP/KI/平滑为全局, 不在此表)."""
        if ch == 2:
            return dict(
                ch=2, freq_cmd="FRQ3", freq_ed=self.ed_f2,
                tau_x_cmd="TAU2X", tau_y_cmd="TAU2Y",
                tau_x_ed=self.ed_t2x, tau_y_ed=self.ed_t2y,
                locked_key="locked_ch2", x_key="ch2_x", y_key="ch2_y",
                buf_key="pll_freq_ch2_hz",
                btn=self.btn_auto_lock2, other_btn=self.btn_auto_lock,
                btn_idle="⚡ 一键自动锁定 CH2",
                latest=lambda: self._latest_freq_ch2,
            )
        return dict(
            ch=1, freq_cmd="FRQ2", freq_ed=self.ed_f1,
            tau_x_cmd="TAU1X", tau_y_cmd="TAU1Y",
            tau_x_ed=self.ed_t1x, tau_y_ed=self.ed_t1y,
            locked_key="locked_ch1", x_key="ch1_x", y_key="ch1_y",
            buf_key="pll_freq_ch1_hz",
            btn=self.btn_auto_lock, other_btn=self.btn_auto_lock2,
            btn_idle="⚡ 一键自动锁定 CH1",
            latest=lambda: self._latest_freq_ch1,
        )

    def _auto_apply_final(self, cfg: dict):
        """判稳后切到用户实测最稳的一组参数: 全局 KP/KI + 本通道 IIR tau + 大平滑."""
        self.ed_kp.setText(str(AUTO_FINAL_KP)); self._send_int_cmd("KP", str(AUTO_FINAL_KP))
        self.ed_ki.setText(str(AUTO_FINAL_KI)); self._send_int_cmd("KI", str(AUTO_FINAL_KI))
        cfg["tau_x_ed"].setText(str(AUTO_FINAL_TAU_X))
        self._send_int_cmd(cfg["tau_x_cmd"], str(AUTO_FINAL_TAU_X))
        cfg["tau_y_ed"].setText(str(AUTO_FINAL_TAU_Y))
        self._send_int_cmd(cfg["tau_y_cmd"], str(AUTO_FINAL_TAU_Y))
        self.ed_freq_sm_n.setText(str(AUTO_SMOOTH_N))
        self._on_freq_sm_changed()

    def _on_auto_lock_clicked(self, ch: int = 1):
        if self._auto_state != "idle":
            self._auto_cancel()
            return
        if not getattr(self.dev, "is_connected", False):
            self.on_log("[!] 自动锁定: 设备未连接")
            return
        cfg = self._auto_cfg(ch)
        try:
            float(cfg["freq_ed"].text())
        except ValueError:
            self.on_log(f"[!] 自动锁定: CH{ch} 起点频率非法")
            return
        self._auto_ch = ch
        self.on_log("[自动] 提示: KP/KI 与锁定阈值为双通道共享, "
                    "捕获期会临时改变全局增益, 可能短暂扰动另一已锁通道.")
        # 1) 下发中心频率 + 稳健捕获参数 (并同步到输入框, 让用户看到)
        self._send_freq_cmd(cfg["freq_cmd"], cfg["freq_ed"].text())
        cfg["tau_y_ed"].setText(str(AUTO_TAU_Y))
        self._send_int_cmd(cfg["tau_y_cmd"], str(AUTO_TAU_Y))
        cfg["tau_x_ed"].setText(str(AUTO_TAU_X))
        self._send_int_cmd(cfg["tau_x_cmd"], str(AUTO_TAU_X))
        self.ed_kp.setText(str(AUTO_KP_BASE)); self._send_int_cmd("KP", str(AUTO_KP_BASE))
        self.ed_ki.setText(str(AUTO_KI_BASE)); self._send_int_cmd("KI", str(AUTO_KI_BASE))
        # 2) 平滑设为中等 (确保启用, N=100) 用于判稳阶段
        self.cb_freq_sm.setChecked(True)
        self.ed_freq_sm_n.setText("100")
        self._on_freq_sm_changed()
        # 3) 启动状态机
        self._auto_state = "wait_lock"
        self._auto_t0 = time.time()
        cfg["btn"].setText(f"■ 取消自动锁定 CH{ch}")
        cfg["btn"].setStyleSheet(
            "background:#a33; color:#fff; font-weight:bold; padding:6px;")
        cfg["other_btn"].setEnabled(False)
        self._auto_timer.start(AUTO_POLL_MS)
        self.on_log(f"[自动] 开始锁定 CH{ch} @ {cfg['freq_ed'].text()} Hz ...")

    def _auto_reset_buttons(self):
        cfg = self._auto_cfg(self._auto_ch)
        cfg["btn"].setText(cfg["btn_idle"])
        cfg["btn"].setStyleSheet(
            "background:#2a6cc0; color:#fff; font-weight:bold; padding:6px;")
        cfg["btn"].setEnabled(True)
        cfg["other_btn"].setEnabled(True)

    def _auto_cancel(self):
        self._auto_timer.stop()
        self._auto_state = "idle"
        self._auto_reset_buttons()
        self.on_log("[自动] 已取消")

    def _auto_finish(self, ok: bool, msg: str):
        self._auto_timer.stop()
        self._auto_state = "idle"
        self._auto_reset_buttons()
        self.on_log(f"[自动] {'✓ 完成' if ok else '✗ 失败'}: {msg}")

    def _auto_step(self):
        fr = getattr(self, "_last_frame", None)
        if fr is None:
            return
        cfg = self._auto_cfg(self._auto_ch)
        now = time.time()
        st = self._auto_state
        locked = bool(fr.get(cfg["locked_key"], False))

        if st == "wait_lock":
            if locked:
                # 软件 AGC: 按幅度 R 自动整定 KP/KI, 使环路增益 ≈ 常数
                R = math.hypot(fr.get(cfg["x_key"], 0), fr.get(cfg["y_key"], 0))
                R = max(R, 1.0)
                kp = int(max(AUTO_KP_RANGE[0],
                             min(AUTO_KP_RANGE[1], AUTO_KP_BASE * AUTO_R_REF / R)))
                ki = int(max(AUTO_KI_RANGE[0],
                             min(AUTO_KI_RANGE[1], AUTO_KI_BASE * AUTO_R_REF / R)))
                self.ed_kp.setText(str(kp)); self._send_int_cmd("KP", str(kp))
                self.ed_ki.setText(str(ki)); self._send_int_cmd("KI", str(ki))
                self.on_log(f"[自动] CH{cfg['ch']} 已锁定; AGC: R={R:.0f} → KP={kp}, KI={ki}")
                self._auto_state = "settle"
                self._auto_t0 = now
            elif now - self._auto_t0 > AUTO_LOCK_TIMEOUT_S:
                self._auto_finish(
                    False,
                    f"CH{cfg['ch']} 超时未锁定 — 请确认中心频率在信号 ±100Hz 内, 且信号确实存在")

        elif st == "settle":
            if not locked and now - self._auto_t0 > AUTO_SETTLE_S:
                self._auto_finish(
                    False, "AGC 后掉锁 (可能增益偏大), 请减小 AUTO_KP_BASE 或手动微调")
            elif now - self._auto_t0 > AUTO_SETTLE_S:
                self._auto_state = "verify"
                self._auto_t0 = now

        elif st == "verify":
            if not locked:
                self._auto_finish(False, "锁定丢失, 请检查信号 / 降低 KP")
                return
            hist = list(self.buf[cfg["buf_key"]])[-AUTO_STABLE_N:]
            stable = (len(hist) >= AUTO_STABLE_N
                      and (max(hist) - min(hist)) < AUTO_STABLE_HZ)
            if stable:
                self._auto_apply_final(cfg)
                self._auto_finish(
                    True,
                    f"CH{cfg['ch']} F={cfg['latest']():.4f} Hz, 已切最终稳定参数"
                    f"(KP={AUTO_FINAL_KP}, KI={AUTO_FINAL_KI}, "
                    f"tau_x={AUTO_FINAL_TAU_X}, tau_y={AUTO_FINAL_TAU_Y}) "
                    f"+ 大平滑(N={AUTO_SMOOTH_N}) → mHz 级")
            elif now - self._auto_t0 > AUTO_VERIFY_TIMEOUT_S:
                self._auto_apply_final(cfg)
                self._auto_finish(
                    True,
                    f"CH{cfg['ch']} 已切最终稳定参数 + 大平滑, 但环路波动稍大 — "
                    "可再加大平滑 N, 或确认参考信号本身是否抖动")

    # ------------------------------------------------------------- 绘图区
    def _build_plot_area(self) -> QWidget:
        # 4 个独立绘图面板, 每个带自己的 header
        # 上左: 通道1 PLL 锁定频率 F1 随时间变化 + F1 锁定灯
        self.panel_ch1 = PlotPanel("通道1 PLL 锁定频率 F1(t)", freq_label="F1",
                                   y_label="频率 (Hz)", left_decimals=3)
        self.curve_freq_ch1 = self.panel_ch1.plot.plot(
            pen=pg.mkPen("#4af", width=PEN_W), name="f1_hz")

        # 上右: 通道2 PLL 锁定频率 F2 随时间变化 + F2 锁定灯
        self.panel_ch2 = PlotPanel("通道2 PLL 锁定频率 F2(t)", freq_label="F2",
                                   y_label="频率 (Hz)", left_decimals=3)
        self.curve_freq_ch2 = self.panel_ch2.plot.plot(
            pen=pg.mkPen("#fa6", width=PEN_W), name="f2_hz")

        # 下左: 解调值 (★ 支持任意多条曲线同时显示)
        self.panel_ch3_har = PlotPanel("解调值", y_label="幅值")

        # ── 顶部控制栏: 信号 ▼   分量 ▼   [+ 添加]  [清空] ──
        har_ctrl_layout = QHBoxLayout()
        har_ctrl_layout.setContentsMargins(10, 0, 10, 0)
        har_ctrl_layout.setSpacing(6)

        self.cb_har_select = QComboBox()
        self.cb_har_select.addItems([OSC1_LBL, OSC2_LBL, OSC3_LBL, DC_LBL])
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

        # ★ 全局电压单位切换 (Peak ↔ RMS), 影响 4 路实时数值 + 所有谐波曲线
        # 相位 Θ 不受影响 (无单位概念).
        self.cb_amp_unit = QComboBox()
        self.cb_amp_unit.addItems(["V_peak", "V_rms"])
        self.cb_amp_unit.setMinimumWidth(85)
        self.cb_amp_unit.setToolTip(
            "电压幅度显示单位:\n"
            "  V_peak = 信号峰值 V₀  (FPGA 原生输出, 默认)\n"
            "  V_rms  = 有效值 V₀/√2 (与 SR830/Zurich 商用锁相对齐)\n"
            "幅值自动换单位: ≥1 V → V; ≥1 mV → mV; 更小 → µV (4 位小数).\n"
            "影响: 4 路实时数值 + 所有谐波/DC 曲线; 相位 Θ 不变."
        )
        self.cb_amp_unit.currentIndexChanged.connect(self._on_amp_unit_changed)

        # ★ 谐波实时数值显示模式切换: X/Y (同相/正交) ⇄ R/Θ (幅值/相位)
        #   一行只显示两个量, 避免四个量挤在一起被截断 (R/Θ 显示不出来).
        self._har_disp_mode = "xy"
        self.btn_har_disp = QPushButton("显示: X/Y")
        self.btn_har_disp.setCheckable(True)
        self.btn_har_disp.setMinimumWidth(92)
        self.btn_har_disp.setToolTip(
            "切换下方 3 路谐波实时数值的显示内容:\n"
            "  未按下 = X/Y (同相 / 正交分量)\n"
            "  按下   = R/Θ (幅值 / 相位)\n"
            "DC 无相位, 两种模式都只显示幅值."
        )
        self.btn_har_disp.clicked.connect(self._on_har_disp_toggled)

        # ★ 运行时标定系数: K_har (谐波 X/Y/R) 和 K_dc (直流) 各自独立.
        # 因为两条通路硬件路径不同, 标定偏差也不一定相同.

        def _mk_calib_k_edit(default: float, kind: str, color: str):
            """构造一组 [QLineEdit][▶] 控件, 返回 (edit, btn)."""
            ed = QLineEdit(f"{default:.4f}")
            ed.setFixedWidth(62)
            ed.setAlignment(Qt.AlignCenter)
            ed.setToolTip(
                f"标定系数 K_{kind} = (真实电压) / (GUI 未标定显示).\n"
                f"  作用: 只影响 {kind.upper()} 通路 (与另一组 K 互不干扰).\n"
                "  K = 1.0 → 用纯理论 ADC/CIC 增益, 不做软件修正.\n"
                "  K < 1 → 缩小;  K > 1 → 放大.\n"
                "建议: 用基准仪器 (Zurich/SR830 测交流 R; 万用表测 DC) 交叉标定后填入."
            )
            btn = QPushButton("▶")
            btn.setFixedSize(28, ed.sizeHint().height())
            btn.setStyleSheet(
                f"QPushButton {{ background:{color}; color:#fff; "
                "font-weight:bold; padding:0px; }"
                f"QPushButton:hover {{ background:#468; }}"
            )
            btn.setToolTip(f"立即应用当前 K_{kind} (Enter 也可生效)")
            return ed, btn

        self.ed_calib_k_har,  self.btn_calib_k_har_apply  = _mk_calib_k_edit(CALIB_K_HAR, "har", "#357")
        self.ed_calib_k_dc,   self.btn_calib_k_dc_apply   = _mk_calib_k_edit(CALIB_K_DC,  "dc",  "#735")
        self.ed_calib_k_har.editingFinished.connect(self._on_calib_k_har_changed)
        self.btn_calib_k_har_apply.clicked.connect(self._on_calib_k_har_changed)
        self.ed_calib_k_dc.editingFinished.connect(self._on_calib_k_dc_changed)
        self.btn_calib_k_dc_apply.clicked.connect(self._on_calib_k_dc_changed)

        har_ctrl_layout.addWidget(QLabel("信号:"))
        har_ctrl_layout.addWidget(self.cb_har_select)
        har_ctrl_layout.addWidget(QLabel("分量:"))
        har_ctrl_layout.addWidget(self.cb_comp_select)
        har_ctrl_layout.addWidget(self.btn_add_curve)
        har_ctrl_layout.addWidget(self.btn_clear_curves)
        har_ctrl_layout.addSpacing(12)
        har_ctrl_layout.addWidget(QLabel("幅度:"))
        har_ctrl_layout.addWidget(self.cb_amp_unit)
        har_ctrl_layout.addSpacing(6)
        har_ctrl_layout.addWidget(self.btn_har_disp)
        har_ctrl_layout.addSpacing(10)
        # K_har 着重颜色区分: 蓝 (谐波)
        lbl_kh = QLabel("K谐波:"); lbl_kh.setStyleSheet("color:#7af;")
        har_ctrl_layout.addWidget(lbl_kh)
        har_ctrl_layout.addWidget(self.ed_calib_k_har)
        har_ctrl_layout.addWidget(self.btn_calib_k_har_apply)
        har_ctrl_layout.addSpacing(6)
        # K_dc 着重颜色区分: 紫红 (直流)
        lbl_kd = QLabel("K直流:"); lbl_kd.setStyleSheet("color:#f9a;")
        har_ctrl_layout.addWidget(lbl_kd)
        har_ctrl_layout.addWidget(self.ed_calib_k_dc)
        har_ctrl_layout.addWidget(self.btn_calib_k_dc_apply)
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
        # 三路谐波: X/Y 或 R/Θ; 电压自动 V/mV/µV, 4 位小数; 相位 Θ 保留 3 位.
        VAL_STYLE = ("color:#ddd; background:#1a1a1a; padding:2px 6px;"
                     " font-family:Consolas, monospace; font-size:9pt;")
        VAL_DEFAULT = "X: ---    Y: ---"

        self.lbl_har_21 = QLabel(f"{OSC1_LBL} │ {VAL_DEFAULT}")
        self.lbl_har_12 = QLabel(f"{OSC2_LBL} │ {VAL_DEFAULT}")
        self.lbl_har_11 = QLabel(f"{OSC3_LBL} │ {VAL_DEFAULT}")
        self.lbl_har_dc = QLabel(f"{DC_LBL}   │ ---")
        for lbl in (self.lbl_har_21, self.lbl_har_12,
                    self.lbl_har_11, self.lbl_har_dc):
            lbl.setStyleSheet(VAL_STYLE)
            lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
            # ★ 横向 Ignored: 长文本标签不再把整列最小宽度撑大 (否则左下面板挤占右列)
            lbl.setSizePolicy(QSizePolicy.Ignored, QSizePolicy.Preferred)

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

        # 初始默认添加一条 (振荡器1, X) 以保持开机就有曲线显示
        self._add_har_curve(OSC1_LBL, "X (同相)")

        self._on_har_select_changed(0)  # 初始化下拉框联动 (DC ↔ 分量禁用)

        # 下右: 通道3 ADC 波形
        self.panel_ch3_adc = PlotPanel("通道3 输入波形", y_label="ADC")
        self.curve_adc_ch3 = self.panel_ch3_adc.plot.plot(
            pen=pg.mkPen("#9af", width=PEN_W), name="adc_ch3")

        # 2x2 网格布局 (★ 强制两列两行等分, 不被某个面板的内容宽度撑歪)
        wrap = QWidget()
        grid = QGridLayout(wrap)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setSpacing(4)
        grid.addWidget(self.panel_ch1, 0, 0)
        grid.addWidget(self.panel_ch2, 0, 1)
        grid.addWidget(self.panel_ch3_har, 1, 0)
        grid.addWidget(self.panel_ch3_adc, 1, 1)
        grid.setColumnStretch(0, 1)
        grid.setColumnStretch(1, 1)
        grid.setRowStretch(0, 1)
        grid.setRowStretch(1, 1)
        for p in (self.panel_ch1, self.panel_ch2,
                  self.panel_ch3_har, self.panel_ch3_adc):
            p.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
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
            /* 三色参数分组: 橙=锁相环  绿=振荡器  蓝=信号发生器 */
            QGroupBox#gbPll {
                border: 2px solid #f80;
                border-radius: 6px;
                margin-top: 14px;
                padding-top: 10px;
                background: #2f2a26;
                font-size: 11pt;
            }
            QGroupBox#gbPll::title {
                subcontrol-origin: margin; left: 10px; padding: 0 8px;
                color: #ffaa44; font-weight: bold; font-size: 11pt;
            }
            QGroupBox#gbOsc {
                border: 2px solid #4a8;
                border-radius: 6px;
                margin-top: 14px;
                padding-top: 10px;
                background: #262f28;
                font-size: 11pt;
            }
            QGroupBox#gbOsc::title {
                subcontrol-origin: margin; left: 10px; padding: 0 8px;
                color: #6c6; font-weight: bold; font-size: 11pt;
            }
            QGroupBox#gbDac {
                border: 2px solid #48c;
                border-radius: 6px;
                margin-top: 14px;
                padding-top: 10px;
                background: #262a2f;
                font-size: 11pt;
            }
            QGroupBox#gbDac::title {
                subcontrol-origin: margin; left: 10px; padding: 0 8px;
                color: #4af; font-weight: bold; font-size: 11pt;
            }
            /* 兼容旧高亮样式 (子面板若仍引用) */
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
            self._send_ref_mode(quiet=True)
            if self.rb_ref_auto.isChecked():
                self._send_all_osc_coefs(quiet=True)
            else:
                self._send_all_osc_src(quiet=True)
                self._send_all_osc_harm(quiet=True)
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

    def _send_freq_cmd(self, cmd, hz_str, quiet=False):
        try:
            hz = float(hz_str)
        except ValueError:
            self.on_log(f"[!] {cmd} 频率非法: {hz_str}")
            return
        # 下发按时基标定反向换算: DDS 用真实(偏差)时钟产生, 物理输出才等于 hz
        word = hz_to_freq_word(hz / self._clk_cal)
        self.dev.send_command(f"{cmd}:{word}")
        if quiet:
            return  # 自动跟随下发: 不逐条刷日志 (由调用方汇总打印一行)
        if self._clk_cal != 1.0:
            self.on_log(f"  ({hz:.3f} Hz → 频率字 {word}, 已按时基标定 k={self._clk_cal:.7f})")
        else:
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
        # ★ 通道3 振荡器: 自动=REFMODE:1+OSC; 手动=REFMODE:0+FRQ21/12/11
        if self.rb_ref_auto.isChecked():
            self._send_all_osc_coefs(quiet=True)
        else:
            self._send_ref_mode(quiet=True)
            self._send_all_osc_src(quiet=True)
            self._send_all_osc_harm(quiet=True)
            for osc in self.ch3_oscs:
                self._send_freq_cmd(osc["frq_cmd"], osc["ed_frq"].text())
        self._send_int_cmd("LOCKSWY", self.ed_swy.text())
        self._send_int_cmd("LOCKTHX", self.ed_thx.text())
        # ★ 通道3 4 路 IIR 阶数 (各路独立, 1..4 = 6/12/18/24 dB/oct)
        self._send_order_one("ORD21", self.cb_order21)
        self._send_order_one("ORD12", self.cb_order12)
        self._send_order_one("ORD11", self.cb_order11)
        self._send_order_one("ORDDC", self.cb_orderdc)
        # ★ 信号发生器 (DAC904): 模式 / 频率 / 相位
        self._send_dac_mode()
        self._send_freq_cmd("DFRQ", self.ed_dac_freq.text())
        self._send_dac_phase(self.ed_dac_phase.text())

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
        is_dc = self.cb_har_select.currentText() == DC_LBL
        if is_dc:
            self.cb_comp_select.setCurrentIndex(2)   # R (幅值)
            self.cb_comp_select.setEnabled(False)
        else:
            self.cb_comp_select.setEnabled(True)

    # ───── 全局电压单位 (V_peak / V_rms) ───────────────────────
    _SQRT2 = math.sqrt(2.0)

    def _amp_scale(self) -> float:
        """返回当前电压乘法系数: V_peak → 1.0; V_rms → 1/√2."""
        if not hasattr(self, "cb_amp_unit"):
            return 1.0
        return 1.0 if self.cb_amp_unit.currentText() == "V_peak" else (1.0 / self._SQRT2)

    def _amp_unit_str(self, base: str = "mV") -> str:
        """返回单位后缀, 例: 'mV' → 'mV' 或 'mVrms';  'µV' → 'µVrms'."""
        if hasattr(self, "cb_amp_unit") and self.cb_amp_unit.currentText() == "V_rms":
            return base + "rms"
        return base

    def _fmt_volt(self, v_volts: float, mult: float, base_unit: str) -> str:
        """格式化为 '±x.xxxx unit' (伏特输入, mult/base_unit 由 auto_voltage_display_unit* 决定)."""
        unit = self._amp_unit_str(base_unit)
        return f"{v_volts * mult:+.{VOLT_DISPLAY_DECIMALS}f} {unit}"

    def _on_amp_unit_changed(self, _idx=0):
        """切换 V_peak ↔ V_rms: 立即刷新一次实时数值 + 曲线."""
        if getattr(self, "_last_frame", None) is not None:
            self._update_har_text()
        if self.t_buf:
            self.refresh_plots()

    # ───── 运行时电压标定系数 K (谐波 / 直流 两组独立) ──────────────
    def _parse_calib_k(self, ed: QLineEdit, old_k: float, name: str) -> float | None:
        """从 LineEdit 解析一个标定 K, 失败时恢复显示并返回 None."""
        text = ed.text().strip()
        try:
            k = float(text)
        except ValueError:
            self.on_log(f"[!] {name} 非法: '{text}', 已恢复原值 {old_k:.4f}")
            ed.setText(f"{old_k:.4f}")
            return None
        if not (1e-3 <= k <= 1e3):
            self.on_log(f"[!] {name} 超范围 (1e-3 ~ 1e3): {k}, 已恢复原值")
            ed.setText(f"{old_k:.4f}")
            return None
        return k

    def _on_calib_k_har_changed(self, *_):
        """K_har 改变 → 只更新 X/Y/R (有混频) 通路换算因子."""
        k = self._parse_calib_k(self.ed_calib_k_har, self._calib_k_har, "K谐波")
        if k is None:
            return
        old_k = self._calib_k_har
        self._calib_k_har = k
        self._v_per_lsb   = k / G_TOTAL
        self._mv_per_lsb  = self._v_per_lsb * 1000.0
        self.on_log(
            f"[i] K谐波 已更新: {old_k:.4f} → {k:.4f}  "
            f"(MV_PER_LSB = {self._mv_per_lsb:.4e})"
        )
        if getattr(self, "_last_frame", None) is not None:
            self._update_har_text()
        if self.t_buf:
            self.refresh_plots()

    def _on_calib_k_dc_changed(self, *_):
        """K_dc 改变 → 只更新 DC (无混频) 通路换算因子."""
        k = self._parse_calib_k(self.ed_calib_k_dc, self._calib_k_dc, "K直流")
        if k is None:
            return
        old_k = self._calib_k_dc
        self._calib_k_dc    = k
        self._v_per_lsb_dc  = k / G_DC
        self._mv_per_lsb_dc = self._v_per_lsb_dc * 1000.0
        self.on_log(
            f"[i] K直流 已更新: {old_k:.4f} → {k:.4f}  "
            f"(MV_PER_LSB_DC = {self._mv_per_lsb_dc:.4e})"
        )
        if getattr(self, "_last_frame", None) is not None:
            self._update_har_text()
        if self.t_buf:
            self.refresh_plots()

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

    # 信号 → (X 键, Y 键) 映射 (直流没有 Y, 用 None 占位)
    _HAR_SIG_KEYS = {
        OSC1_LBL: ("ch3_x_21", "ch3_y_21"),
        OSC2_LBL: ("ch3_x_12", "ch3_y_12"),
        OSC3_LBL: ("ch3_x_11", "ch3_y_11"),
        DC_LBL:   ("ch3_dc",   None),
    }

    def _refresh_har_curves(self, t: np.ndarray):
        """遍历 self.har_curves, 把每条曲线的数据 setData 进去.

        - 电压类 (X/Y/R/DC) 跟随全局 V_peak / V_rms 单位切换 (Θ 不变).
        - 电压纵轴按当前曲线幅度自动 V / mV / µV.
        """
        if not self.har_curves:
            self.panel_ch3_har.plot.setLabel("left", "幅值")
            return

        scale    = self._amp_scale()
        v_lsb    = self._v_per_lsb
        v_lsb_dc = self._v_per_lsb_dc

        pending_voltage: list[tuple[dict, np.ndarray]] = []
        has_phase = False

        for it in self.har_curves:
            sig  = it["sig"]
            comp = it["comp"]
            kx, ky = self._HAR_SIG_KEYS[sig]

            this_v_lsb = v_lsb_dc if sig == DC_LBL else v_lsb
            arr_x = np.asarray(self.buf[kx], dtype=float) * this_v_lsb
            if ky is None:
                arr_y = np.zeros_like(arr_x)
            else:
                arr_y = np.asarray(self.buf[ky], dtype=float) * this_v_lsb

            if comp.startswith("X"):
                y_volts = arr_x * scale
                pending_voltage.append((it, y_volts))
            elif comp.startswith("Y"):
                y_volts = arr_y * scale
                pending_voltage.append((it, y_volts))
            elif comp.startswith("R"):
                y_volts = np.sqrt(arr_x * arr_x + arr_y * arr_y) * scale
                pending_voltage.append((it, y_volts))
            else:  # Θ
                y_data = np.degrees(np.arctan2(arr_y, arr_x))
                it["curve"].setData(t, y_data)
                has_phase = True

        has_voltage = bool(pending_voltage)
        if has_voltage:
            max_abs = 0.0
            for _, y_volts in pending_voltage:
                if y_volts.size:
                    max_abs = max(max_abs, float(np.max(np.abs(y_volts))))
            mult, base_u = auto_voltage_display_unit_for(max_abs)
            unit_v = self._amp_unit_str(base_u)
            for it, y_volts in pending_voltage:
                it["curve"].setData(t, y_volts * mult)

        if has_voltage and has_phase:
            self.panel_ch3_har.plot.setLabel("left", f"电压 ({unit_v}) / 相位 (°)")
        elif has_phase:
            self.panel_ch3_har.plot.setLabel("left", "相位 (°)")
        elif has_voltage:
            self.panel_ch3_har.plot.setLabel("left", f"电压 ({unit_v})")
        else:
            self.panel_ch3_har.plot.setLabel("left", "幅值")

    # 谐波 X/Y 数据键名映射 (顺序与 lbl_har_21/12/11 对应)
    _HAR_KEYS = (
        (OSC1_LBL, "ch3_x_21", "ch3_y_21"),
        (OSC2_LBL, "ch3_x_12", "ch3_y_12"),
        (OSC3_LBL, "ch3_x_11", "ch3_y_11"),
    )

    def _on_har_disp_toggled(self, *_):
        """切换谐波实时数值显示: X/Y ⇄ R/Θ."""
        self._har_disp_mode = "rt" if self.btn_har_disp.isChecked() else "xy"
        self.btn_har_disp.setText(
            "显示: R/Θ" if self._har_disp_mode == "rt" else "显示: X/Y")
        self._update_har_text()

    def _update_har_text(self, *_):
        """每一帧把 4 路 (3 谐波 + DC) 的实时值全部刷新.
        电压按幅度自动 V/mV/µV (4 位小数); 相位 Θ 仍用 °.
        """
        d = self._last_frame
        if d is None:
            return

        scale  = self._amp_scale()
        v_lsb  = self._v_per_lsb

        rt = (self._har_disp_mode == "rt")
        for lbl, (name, kx, ky) in zip(
            (self.lbl_har_21, self.lbl_har_12, self.lbl_har_11),
            self._HAR_KEYS,
        ):
            x_v = d.get(kx, 0) * v_lsb * scale
            y_v = d.get(ky, 0) * v_lsb * scale
            if rt:
                r_v = math.sqrt(x_v * x_v + y_v * y_v)
                theta_deg = math.degrees(math.atan2(y_v, x_v))
                mult, base = auto_voltage_display_unit_for(r_v)
                lbl.setText(
                    f"{name} │ R: {self._fmt_volt(r_v, mult, base):>16}"
                    f"    Θ: {theta_deg:>+9.3f}°")
            else:
                mult, base = auto_voltage_display_unit_for(x_v, y_v)
                lbl.setText(
                    f"{name} │ X: {self._fmt_volt(x_v, mult, base):>16}"
                    f"    Y: {self._fmt_volt(y_v, mult, base):>16}")

        dc_v = d.get("ch3_dc", 0) * self._v_per_lsb_dc * scale
        mult, base = auto_voltage_display_unit_for(dc_v)
        self.lbl_har_dc.setText(
            f"{DC_LBL}   │ {self._fmt_volt(dc_v, mult, base):>16}   (无 Θ)")

    # ============================================================ 数据接收
    def on_frame(self, data: dict):
        self.frame_count += 1
        # ★ 时基标定: 把按标称 65MHz 反算的锁定频率修正到真实物理频率 (k=1 时不变)
        if self._clk_cal != 1.0:
            if "pll_freq_ch1_hz" in data:
                data["pll_freq_ch1_hz"] *= self._clk_cal
            if "pll_freq_ch2_hz" in data:
                data["pll_freq_ch2_hz"] *= self._clk_cal
        # ★ 锁定频率后置平滑 (读数精度): 独立于环路, 大跳变自动重置以快速跟随
        if "pll_freq_ch1_hz" in data:
            data["pll_freq_ch1_hz"] = self._smooth_freq(
                0, data["pll_freq_ch1_hz"], data.get("locked_ch1", False))
        if "pll_freq_ch2_hz" in data:
            data["pll_freq_ch2_hz"] = self._smooth_freq(
                1, data["pll_freq_ch2_hz"], data.get("locked_ch2", False))
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

        # 自动模式: 三路谐波 ref 实时跟随实测锁定频率 (节流: 每 5 帧刷新一次)
        if self.frame_count % 5 == 0:
            self._track_ref_freqs()

        # ★ 诊断: 用回读的硬件实际参考频率覆盖显示 (放最后, 保证不被估算值盖掉)
        self._update_osc_readback(data)

        if self.csv_writer:
            try:
                self.csv_writer.writerow(self._build_csv_row(data))
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
    # CSV 表头. 列定义:
    #   timestamp                绝对时间戳 (Unix epoch, 秒)
    #   pll_freq_ch1_hz / ch2_hz PLL 锁定频率 (Hz, 由频率字反算)
    #   locked_ch1 / locked_ch2  PLL 锁定标志 (0/1)
    #   ch3_21_X_mV ... theta_deg  通道3 @ 2F1+F2: X, Y, R(=√(X²+Y²)), Θ(=atan2(Y,X))
    #   ch3_12_X_mV ... theta_deg  通道3 @ F1+2F2 同上
    #   ch3_11_X_mV ... theta_deg  通道3 @ F1+F2  同上
    #   ch3_dc_mV                通道3 DC 通路电压
    #   ch1_X_mV/Y/R/theta       通道1 PLL 内部 X/Y (锁相过程的 in-phase / quadrature)
    #   ch2_X_mV/Y/R/theta       通道2 PLL 内部 X/Y
    #   adc_ch1/2/3_LSB          原始 ADC 14bit 码值 (-8192 ~ 8191), 追溯用
    #
    # ★ 电压单位固定为 "mV peak", 不随 GUI 显示 (Peak / RMS) 切换变化
    #   想要 RMS, 事后乘 1/√2 即可
    CSV_COLUMNS = [
        "timestamp",
        "pll_freq_ch1_hz", "pll_freq_ch2_hz", "locked_ch1", "locked_ch2",
        # --- 通道3 三谐波: X, Y, R, theta(°) ---
        "ch3_21_X_mV", "ch3_21_Y_mV", "ch3_21_R_mV", "ch3_21_theta_deg",
        "ch3_12_X_mV", "ch3_12_Y_mV", "ch3_12_R_mV", "ch3_12_theta_deg",
        "ch3_11_X_mV", "ch3_11_Y_mV", "ch3_11_R_mV", "ch3_11_theta_deg",
        # --- 通道3 DC ---
        "ch3_dc_mV",
        # --- 通道1/2 PLL 内部 X/Y/R/theta ---
        "ch1_X_mV", "ch1_Y_mV", "ch1_R_mV", "ch1_theta_deg",
        "ch2_X_mV", "ch2_Y_mV", "ch2_R_mV", "ch2_theta_deg",
        # --- 原始 ADC (LSB) ---
        "adc_ch1_LSB", "adc_ch2_LSB", "adc_ch3_LSB",
    ]

    def _build_csv_row(self, d: dict) -> list:
        """按 CSV_COLUMNS 顺序生成一行电压/相位数据.
        电压一律按 mV peak 输出, 不受 GUI Unit 切换影响.
        """
        mv      = self._mv_per_lsb           # 谐波 / PLL 通路 LSB → mV
        mv_dc   = self._mv_per_lsb_dc        # DC 通路 LSB → mV (不同增益)

        def _xy_block(kx: str, ky: str):
            """根据 X/Y 字段名计算 (X, Y, R, theta) 四个值 (mV / °)"""
            x = d.get(kx, 0) * mv
            y = d.get(ky, 0) * mv
            r = math.sqrt(x * x + y * y)
            th = math.degrees(math.atan2(y, x))
            return x, y, r, th

        row = [
            f"{d.get('timestamp', 0.0):.6f}",
            f"{d.get('pll_freq_ch1_hz', 0.0):.6f}",
            f"{d.get('pll_freq_ch2_hz', 0.0):.6f}",
            int(bool(d.get("locked_ch1", False))),
            int(bool(d.get("locked_ch2", False))),
        ]
        for kx, ky in (("ch3_x_21", "ch3_y_21"),
                       ("ch3_x_12", "ch3_y_12"),
                       ("ch3_x_11", "ch3_y_11")):
            x, y, r, th = _xy_block(kx, ky)
            row += [f"{x:.6f}", f"{y:.6f}", f"{r:.6f}", f"{th:.4f}"]
        row.append(f"{d.get('ch3_dc', 0) * mv_dc:.6f}")
        for kx, ky in (("ch1_x", "ch1_y"), ("ch2_x", "ch2_y")):
            x, y, r, th = _xy_block(kx, ky)
            row += [f"{x:.6f}", f"{y:.6f}", f"{r:.6f}", f"{th:.4f}"]
        row += [d.get("adc_ch1", 0), d.get("adc_ch2", 0), d.get("adc_ch3", 0)]
        return row

    def _write_csv_metadata_header(self, f):
        """在 CSV 第一行之前, 用 '#' 注释行写入元数据.
        pandas 读取时用 pd.read_csv(path, comment='#') 即可自动跳过.
        """
        meta_lines = [
            f"# Lockin GUI Recording",
            f"# recorded_at      = {time.strftime('%Y-%m-%d %H:%M:%S')}",
            f"# voltage_unit     = mV peak (NOT scaled by GUI Peak/RMS switch)",
            f"# phase_unit       = degree (atan2(Y, X))",
            f"# CALIB_K_HAR      = {self._calib_k_har:.6f}",
            f"# CALIB_K_DC       = {self._calib_k_dc:.6f}",
            f"# MV_PER_LSB       = {self._mv_per_lsb:.6e}  # 谐波/PLL 通路: LSB -> mV",
            f"# MV_PER_LSB_DC    = {self._mv_per_lsb_dc:.6e}  # DC 通路:    LSB -> mV",
            f"# ADC_FS_V         = {ADC_FS_V:.4f}",
            f"# F_CLK_Hz         = {F_CLK}",
            f"# CLK_CAL_k        = {self._clk_cal:.9f}  # 时基标定: 真实/标称, 已乘入 pll_freq",
            f"# CLK_CAL_ppm      = {(self._clk_cal - 1.0) * 1e6:+.3f}",
            f"#",
        ]
        f.write("\n".join(meta_lines) + "\n")

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
                self._write_csv_metadata_header(self.csv_file)
                self.csv_writer = csv.writer(self.csv_file)
                self.csv_writer.writerow(self.CSV_COLUMNS)
                self.btn_record.setText("⏹ 停止录制")
                self.btn_record.setStyleSheet("background:#a33; color:white;")
                self.lbl_status_rec.setText(f"● 录制中: {path.split('/')[-1]}")
                self.lbl_status_rec.setStyleSheet("color:#f55;")
                self.on_log(f"[+] 开始录制: {path}")
                self.on_log(f"    电压单位 = mV peak (CALIB_K_HAR={self._calib_k_har:.4f}, "
                            f"K_DC={self._calib_k_dc:.4f})")
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
