"""
scope_window.py
───────────────
示波器窗口: AD7606C 通道 V5 / V6 真实波形 (FPGA scope_cap 以最高 1 MSPS 抓 1024 点后整段上传)

流程: 下发 SDEC (抽取) / STLV (触发电平) → SCAP (启动抓取) → FPGA 抓完上传一包
      → device.scope_received → 画图 → 运行模式下自动再发 SCAP.
须先「开始数据流」(接收线程负责从上行字节流中解析示波器包).
"""

import time

import numpy as np
import pyqtgraph as pg
from PyQt5.QtCore import Qt, QTimer
from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QGridLayout, QLabel, QLineEdit,
    QPushButton, QComboBox, QCheckBox, QFrame,
)

from device import SCOPE_ADC_HZ, SCOPE_V_PER_LSB

CH_COLORS = {"V5": "#fc5", "V6": "#4df"}

# 时基: (抽取 n, 每 n+1 个 ADC 样点存 1 点)
TIMEBASE_DECIMS = [0, 1, 4, 9, 19, 49, 99, 199, 499, 999]

TRIG_SRC_ITEMS = [("V5", 0), ("V6", 1), ("无 (自由运行)", -1)]
TRIG_EDGE_ITEMS = [("上升沿", 0), ("下降沿", 1)]
TRIG_SWEEP_ITEMS = [("自动", 0), ("正常", 1)]
Y_RANGE_ITEMS = [("自动", None), ("±10 V", 10.0), ("±5 V", 5.0),
                 ("±2 V", 2.0), ("±1 V", 1.0), ("±0.5 V", 0.5), ("±0.1 V", 0.1)]

MIN_REARM_S = 0.05        # 运行模式最高约 20 次/秒刷新
WATCHDOG_MS = 500


def _fmt_time(sec: float) -> str:
    if sec >= 1:
        return f"{sec:g} s"
    if sec >= 1e-3:
        return f"{sec * 1e3:g} ms"
    return f"{sec * 1e6:g} µs"


def _fmt_volt(v: float) -> str:
    a = abs(v)
    if a >= 1:
        return f"{v:.3f} V"
    if a >= 1e-3:
        return f"{v * 1e3:.2f} mV"
    return f"{v * 1e6:.0f} µV"


def _fmt_freq(f: float) -> str:
    if f >= 1e3:
        return f"{f / 1e3:.3f} kHz"
    return f"{f:.2f} Hz"


def estimate_freq(v: np.ndarray, dt: float) -> float | None:
    """去均值后按带迟滞的上升过零点估计频率 (过零时刻线性插值)"""
    if v.size < 8:
        return None
    x = v - v.mean()
    hyst = 0.1 * (x.max() - x.min()) / 2
    if hyst <= 0:
        return None
    crossings = []
    armed = False
    for i in range(1, x.size):
        if x[i - 1] < -hyst:
            armed = True
        if armed and x[i - 1] < 0 <= x[i]:
            frac = -x[i - 1] / (x[i] - x[i - 1])
            crossings.append((i - 1 + frac) * dt)
            armed = False
    if len(crossings) < 2:
        return None
    return (len(crossings) - 1) / (crossings[-1] - crossings[0])


class ScopeWindow(QWidget):
    def __init__(self, dev, parent=None):
        super().__init__(parent, Qt.Window)
        self.dev = dev
        self.setWindowTitle("示波器 · V5 / V6 (AD7606C)")
        self.resize(1100, 640)

        self._running = False          # 连续运行 (收到一包后自动再抓)
        self._waiting = False          # 已发 SCAP, 等数据
        self._arm_t = 0.0
        self._last_pkt_t = 0.0
        self._pkt_times: list[float] = []
        self._x_key = None

        self._build_ui()
        dev.scope_received.connect(self.on_scope_packet)

        self._watchdog = QTimer(self)
        self._watchdog.timeout.connect(self._on_watchdog)
        self._watchdog.start(WATCHDOG_MS)

    # ------------------------------------------------------------------ UI
    def _build_ui(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(8, 8, 8, 8)
        root.setSpacing(6)

        # 第一行: 运行控制 + 时基 + 显示
        row1 = QHBoxLayout()
        self.btn_run = QPushButton("▶ 运行")
        self.btn_run.setCheckable(True)
        self.btn_run.setMinimumWidth(90)
        self.btn_run.clicked.connect(self._on_run_clicked)
        self.btn_single = QPushButton("单次")
        self.btn_single.clicked.connect(self._on_single_clicked)
        row1.addWidget(self.btn_run)
        row1.addWidget(self.btn_single)
        row1.addSpacing(16)

        row1.addWidget(QLabel("时基:"))
        self.cb_timebase = QComboBox()
        for d in TIMEBASE_DECIMS:
            dt = (d + 1) / SCOPE_ADC_HZ
            rate = SCOPE_ADC_HZ / (d + 1)
            rate_s = f"{rate / 1e6:g} MSa/s" if rate >= 1e6 else f"{rate / 1e3:g} kSa/s"
            self.cb_timebase.addItem(f"一屏 {_fmt_time(1024 * dt)}  ({rate_s})", d)
        self.cb_timebase.setToolTip("一屏固定 1024 点; 抽取越大, 一屏时间越长 (无抗混叠滤波)")
        self.cb_timebase.currentIndexChanged.connect(self._on_cfg_changed)
        row1.addWidget(self.cb_timebase)
        row1.addSpacing(16)

        row1.addWidget(QLabel("显示:"))
        self.chk_ch = {}
        for name in ("V5", "V6"):
            chk = QCheckBox(name)
            chk.setChecked(True)
            chk.setStyleSheet(f"QCheckBox {{ color:{CH_COLORS[name]}; font-weight:bold; }}")
            chk.toggled.connect(self._on_visible_changed)
            self.chk_ch[name] = chk
            row1.addWidget(chk)
        row1.addSpacing(16)

        row1.addWidget(QLabel("纵轴:"))
        self.cb_yrange = QComboBox()
        for text, val in Y_RANGE_ITEMS:
            self.cb_yrange.addItem(text, val)
        self.cb_yrange.currentIndexChanged.connect(self._apply_yrange)
        row1.addWidget(self.cb_yrange)
        row1.addStretch()
        root.addLayout(row1)

        # 第二行: 触发
        row2 = QHBoxLayout()
        row2.addWidget(QLabel("触发源:"))
        self.cb_trig_src = QComboBox()
        for text, val in TRIG_SRC_ITEMS:
            self.cb_trig_src.addItem(text, val)
        self.cb_trig_src.currentIndexChanged.connect(self._on_cfg_changed)
        row2.addWidget(self.cb_trig_src)

        row2.addWidget(QLabel("边沿:"))
        self.cb_trig_edge = QComboBox()
        for text, val in TRIG_EDGE_ITEMS:
            self.cb_trig_edge.addItem(text, val)
        self.cb_trig_edge.currentIndexChanged.connect(self._on_cfg_changed)
        row2.addWidget(self.cb_trig_edge)

        row2.addWidget(QLabel("扫描:"))
        self.cb_sweep = QComboBox()
        for text, val in TRIG_SWEEP_ITEMS:
            self.cb_sweep.addItem(text, val)
        self.cb_sweep.setToolTip("自动: 等不到触发 (≥100 ms 且 ≥ 一屏时长) 就强制刷新\n"
                                 "正常: 只在真实触发时刷新")
        self.cb_sweep.currentIndexChanged.connect(self._on_cfg_changed)
        row2.addWidget(self.cb_sweep)

        row2.addWidget(QLabel("电平 (V):"))
        self.ed_level = QLineEdit("0.000")
        self.ed_level.setFixedWidth(70)
        self.ed_level.setAlignment(Qt.AlignCenter)
        self.ed_level.setToolTip("触发电平, 也可直接拖动图中的水平虚线")
        self.ed_level.editingFinished.connect(self._on_level_edited)
        row2.addWidget(self.ed_level)
        row2.addSpacing(16)

        self.lbl_status = QLabel("已停止")
        self.lbl_status.setStyleSheet("color:#aaa;")
        row2.addWidget(self.lbl_status)
        row2.addStretch()
        root.addLayout(row2)

        # 图
        self.plot = pg.PlotWidget()
        self.plot.showGrid(x=True, y=True, alpha=0.3)
        self.plot.setLabel("bottom", "时间 (相对触发点)", units="s")
        self.plot.setLabel("left", "电压", units="V")
        self.plot.setToolTip("滚轮缩放 / 拖动平移; 右键 → View All 恢复整屏")
        self.plot.addLegend(offset=(10, 10), labelTextSize="9pt")
        self.plot.setAntialiasing(False)
        self.curves = {
            name: self.plot.plot(pen=pg.mkPen(CH_COLORS[name], width=1.2), name=name)
            for name in ("V5", "V6")
        }
        self.line_t0 = pg.InfiniteLine(pos=0, angle=90,
                                       pen=pg.mkPen("#888", style=Qt.DashLine))
        self.plot.addItem(self.line_t0)
        self.line_level = pg.InfiniteLine(pos=0.0, angle=0, movable=True,
                                          pen=pg.mkPen("#f66", style=Qt.DashLine))
        self.line_level.sigPositionChangeFinished.connect(self._on_level_dragged)
        self.plot.addItem(self.line_level)
        root.addWidget(self.plot, 1)

        # 测量
        meas = QGridLayout()
        meas.setHorizontalSpacing(12)
        style = ("background:#1a1a1a; padding:2px 6px; "
                 "font-family:Consolas, monospace; font-size:9pt;")
        self.lbl_meas = {}
        for r, name in enumerate(("V5", "V6")):
            lbl = QLabel(f"{name} │ ---")
            lbl.setStyleSheet(f"color:{CH_COLORS[name]}; {style}")
            lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
            meas.addWidget(lbl, r, 0)
            self.lbl_meas[name] = lbl
        self.lbl_phase = QLabel("V6 相对 V5 相位差: ---")
        self.lbl_phase.setStyleSheet(f"color:#ddd; {style}")
        meas.addWidget(self.lbl_phase, 2, 0)
        frame = QFrame()
        frame.setLayout(meas)
        root.addWidget(frame)

        self._apply_yrange()

    # ------------------------------------------------------------ 配置/命令
    def _trig_mode_word(self) -> int:
        src = self.cb_trig_src.currentData()
        if src < 0:
            mode = 0
        else:
            mode = 1 + 2 * src + self.cb_trig_edge.currentData()
        if self.cb_sweep.currentData() == 1 and mode != 0:
            mode |= 0x8
        return mode

    def _level_v(self) -> float:
        try:
            return float(self.ed_level.text())
        except ValueError:
            return 0.0

    def _send_cfg(self):
        decim = self.cb_timebase.currentData()
        code = int(round(self._level_v() / SCOPE_V_PER_LSB))
        code = max(-32768, min(32767, code))
        self.dev.send_command(f"SDEC:{decim}", quiet=True)
        self.dev.send_command(f"STLV:{code + 32768}", quiet=True)

    def _arm(self):
        if not self._can_capture():
            self._stop()
            return
        self.dev.send_command(f"SCAP:{self._trig_mode_word()}", quiet=True)
        self._waiting = True
        self._arm_t = time.time()

    def _can_capture(self) -> bool:
        if not self.dev.is_streaming:
            self.lbl_status.setText("请先在主窗口「开始数据流」")
            return False
        return True

    def _start(self, continuous: bool):
        if not self._can_capture():
            self.btn_run.setChecked(False)
            return
        self._running = continuous
        self.btn_run.setChecked(continuous)
        self.btn_run.setText("■ 停止" if continuous else "▶ 运行")
        self._pkt_times.clear()
        self._send_cfg()
        self._arm()
        self.lbl_status.setText("等待触发…")

    def _stop(self):
        self._running = False
        self._waiting = False
        self.btn_run.setChecked(False)
        self.btn_run.setText("▶ 运行")

    def stop(self):
        """主窗口停止数据流时调用"""
        self._stop()
        self.lbl_status.setText("已停止")

    def _on_run_clicked(self, checked: bool):
        if checked:
            self._start(continuous=True)
        else:
            self.stop()

    def _on_single_clicked(self):
        self._start(continuous=False)

    def _on_cfg_changed(self, *_):
        self.cb_trig_edge.setEnabled(self.cb_trig_src.currentData() >= 0)
        if self._running or self._waiting:
            self._send_cfg()
            self._arm()

    def _on_level_edited(self):
        v = max(-10.0, min(10.0, self._level_v()))
        self.ed_level.setText(f"{v:.3f}")
        self.line_level.setValue(v)
        self._on_cfg_changed()

    def _on_level_dragged(self, *_):
        v = max(-10.0, min(10.0, self.line_level.value()))
        self.ed_level.setText(f"{v:.3f}")
        self._on_cfg_changed()

    def _on_visible_changed(self, *_):
        for name, chk in self.chk_ch.items():
            self.curves[name].setVisible(chk.isChecked())

    def _apply_yrange(self, *_):
        r = self.cb_yrange.currentData()
        if r is None:
            self.plot.enableAutoRange(axis="y")
        else:
            self.plot.setYRange(-r, r, padding=0.02)

    def _on_watchdog(self):
        # 示波器包偶尔因 CRC 被丢: 超时无回包就重发 SCAP
        if not self._waiting:
            return
        if not self.dev.is_streaming:
            self.stop()
            self.lbl_status.setText("数据流已停止")
            return
        window = 1024 * (self.cb_timebase.currentData() + 1) / SCOPE_ADC_HZ
        normal = bool(self._trig_mode_word() & 0x8)
        if time.time() - self._arm_t > (3.0 if normal else 1.0) + 3 * window:
            self._arm()

    # ------------------------------------------------------------------ 数据
    def on_scope_packet(self, pkt: dict):
        if not self._waiting:
            return
        self._waiting = False
        now = time.time()
        self._pkt_times = [t for t in self._pkt_times if now - t < 2.0] + [now]

        n, pre, dt = pkt["n"], pkt["pre"], pkt["dt"]
        t = (np.arange(n) - pre) * dt
        volts = {"V5": pkt["a"] * SCOPE_V_PER_LSB, "V6": pkt["b"] * SCOPE_V_PER_LSB}
        for name, v in volts.items():
            self.curves[name].setData(t, v)
            self._update_meas(name, v, dt)
        self._update_delay(volts["V5"], volts["V6"], dt)
        # 只在时基变化时重置横轴, 保留用户用滚轮放大的视图
        x_key = (n, pre, dt)
        if x_key != self._x_key:
            self._x_key = x_key
            self.plot.setXRange(t[0], t[-1], padding=0)

        trig = "自由运行" if pkt["mode"] == 0 else ("自动 (未触发)" if pkt["forced"] else "已触发")
        rate = (len(self._pkt_times) - 1) / (self._pkt_times[-1] - self._pkt_times[0]) \
            if len(self._pkt_times) > 1 else 0.0
        bad = getattr(self.dev, "bad_scope_packets", 0)
        self.lbl_status.setText(
            f"{trig}   采样间隔 {_fmt_time(dt)}   刷新 {rate:.1f}/s   "
            f"包序号 {pkt['seq']}   坏包 {bad}")

        if self._running:
            wait_ms = int(max(0.0, MIN_REARM_S - (now - self._last_pkt_t)) * 1000)
            self._last_pkt_t = now
            QTimer.singleShot(wait_ms, self._rearm_if_running)
        else:
            self._stop()

    def _rearm_if_running(self):
        if self._running and not self._waiting:
            self._arm()

    def _update_meas(self, name: str, v: np.ndarray, dt: float):
        vpp = float(v.max() - v.min())
        mean = float(v.mean())
        rms = float(np.sqrt(np.mean((v - mean) ** 2)))
        f = estimate_freq(v, dt)
        f_s = _fmt_freq(f) if f else "---"
        self.lbl_meas[name].setText(
            f"{name} │ 峰峰值 {_fmt_volt(vpp):>10}   平均 {_fmt_volt(mean):>10}   "
            f"交流有效值 {_fmt_volt(rms):>10}   频率 {f_s}")

    def _update_delay(self, a: np.ndarray, b: np.ndarray, dt: float):
        """在 V5 频率上做单点 DFT, 求 V6 相对 V5 的相位差 (两路同频时才有意义)"""
        fa, fb = estimate_freq(a, dt), estimate_freq(b, dt)
        if not fa or not fb or abs(fa - fb) > 0.02 * fa:
            self.lbl_phase.setText("V6 相对 V5 相位差: --- (两路频率不同)")
            return
        # 截到整数个周期, 减小单点 DFT 的泄漏
        n = int(int(a.size * dt * fa) / (fa * dt))
        if n < 8:
            n = a.size
        t = np.arange(n) * dt
        ref = np.exp(-2j * np.pi * fa * t)
        za = np.dot(a[:n] - a[:n].mean(), ref)
        zb = np.dot(b[:n] - b[:n].mean(), ref)
        dphi = float(np.degrees(np.angle(zb / za))) if abs(za) > 0 else 0.0
        delay = -dphi / 360.0 / fa
        tag = " (V6 滞后)" if delay > 0 else (" (V6 超前)" if delay < 0 else "")
        self.lbl_phase.setText(
            f"V6 相对 V5 相位差 {dphi:+.2f}°   时延 {_fmt_time(abs(delay)) if delay else '0'}{tag}")

    def closeEvent(self, event):
        self.stop()
        super().closeEvent(event)
