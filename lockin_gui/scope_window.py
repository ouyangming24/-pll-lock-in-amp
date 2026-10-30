"""
scope_window.py
───────────────
示波器窗口, 两种显示模式:

  1) V5 / V6 — 硬件示波器 (scope_cap, 最高 1 MSPS × 1024 点, SCAP)
  2) V3 / V4 / V5 — 数据流软画 (SDKOUT 每帧瞬时样点滚动画; 约 kHz 级, 无硬件触发)

V3/V4/V5 模式会把数据流切到 SDKOUT (与主窗口 XYOUT 互斥); 退出该模式或关闭窗口时切回 XYOUT.
"""

import time
from collections import deque

import numpy as np
import pyqtgraph as pg
from PyQt5.QtCore import Qt, QTimer
from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QGridLayout, QLabel, QLineEdit,
    QPushButton, QComboBox, QCheckBox, QFrame,
)

from device import SCOPE_ADC_HZ, SCOPE_V_PER_LSB, SAMPLE_TICK_S

MODE_HW56 = "hw56"
MODE_SOFT345 = "soft345"

CH_COLORS = {
    "V3": "#f96", "V4": "#9c6", "V5": "#fc5", "V6": "#4df",
}

TIMEBASE_DECIMS = [0, 1, 4, 9, 19, 49, 99, 199, 499, 999]
SOFT_LEN_ITEMS = [256, 512, 1024, 2048, 4096]

TRIG_SRC_ITEMS = [("V5", 0), ("V6", 1), ("无 (自由运行)", -1)]
TRIG_EDGE_ITEMS = [("上升沿", 0), ("下降沿", 1)]
TRIG_SWEEP_ITEMS = [("自动", 0), ("正常", 1)]
Y_RANGE_ITEMS = [("自动", None), ("±10 V", 10.0), ("±5 V", 5.0),
                 ("±2 V", 2.0), ("±1 V", 1.0), ("±0.5 V", 0.5), ("±0.1 V", 0.1)]

MIN_REARM_S = 0.05
WATCHDOG_MS = 500
SOFT_REFRESH_MS = 50


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
        self.setWindowTitle("示波器 · V5/V6 或 V3/V4/V5")
        self.resize(1100, 640)

        self._mode = MODE_HW56
        self._running = False
        self._waiting = False
        self._arm_t = 0.0
        self._last_pkt_t = 0.0
        self._pkt_times: list[float] = []
        self._x_key = None
        self._soft_active = False
        self._soft_t0 = 0.0
        self._soft_n = 0
        n0 = 1024
        self._soft_buf = {
            "V3": deque(maxlen=n0),
            "V4": deque(maxlen=n0),
            "V5": deque(maxlen=n0),
            "cnt": deque(maxlen=n0),
        }

        self._build_ui()
        dev.scope_received.connect(self.on_scope_packet)
        if hasattr(dev, "sdk_received"):
            dev.sdk_received.connect(self.on_sdk_frame)

        self._watchdog = QTimer(self)
        self._watchdog.timeout.connect(self._on_watchdog)
        self._watchdog.start(WATCHDOG_MS)

        self._soft_timer = QTimer(self)
        self._soft_timer.timeout.connect(self._refresh_soft_plot)
        self._soft_timer.setInterval(SOFT_REFRESH_MS)

        self._apply_mode_ui()

    def _build_ui(self):
        root = QVBoxLayout(self)
        root.setContentsMargins(8, 8, 8, 8)
        root.setSpacing(6)

        row0 = QHBoxLayout()
        row0.addWidget(QLabel("通道模式:"))
        self.cb_mode = QComboBox()
        self.cb_mode.addItem("V5 + V6 (硬件示波器 1 MSa/s)", MODE_HW56)
        self.cb_mode.addItem("V3 + V4 + V5 (数据流软画, 切 SDKOUT)", MODE_SOFT345)
        self.cb_mode.setToolTip(
            "V5/V6: FPGA 硬件缓存抓取, 可与主窗口 XYOUT 同时使用\n"
            "V3/V4/V5: 切到 SDKOUT 连续取瞬时样点; 主窗口锁相曲线会暂停, "
            "退出本模式或关闭窗口后自动切回 XYOUT")
        self.cb_mode.currentIndexChanged.connect(self._on_mode_changed)
        row0.addWidget(self.cb_mode)
        row0.addStretch()
        root.addLayout(row0)

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

        self.lbl_timebase = QLabel("时基:")
        row1.addWidget(self.lbl_timebase)
        self.cb_timebase = QComboBox()
        for d in TIMEBASE_DECIMS:
            dt = (d + 1) / SCOPE_ADC_HZ
            rate = SCOPE_ADC_HZ / (d + 1)
            rate_s = f"{rate / 1e6:g} MSa/s" if rate >= 1e6 else f"{rate / 1e3:g} kSa/s"
            self.cb_timebase.addItem(f"一屏 {_fmt_time(1024 * dt)}  ({rate_s})", d)
        self.cb_timebase.currentIndexChanged.connect(self._on_cfg_changed)
        row1.addWidget(self.cb_timebase)

        self.lbl_soft_len = QLabel("一屏点数:")
        row1.addWidget(self.lbl_soft_len)
        self.cb_soft_len = QComboBox()
        for n in SOFT_LEN_ITEMS:
            self.cb_soft_len.addItem(str(n), n)
        self.cb_soft_len.setCurrentIndex(2)
        self.cb_soft_len.currentIndexChanged.connect(self._on_soft_len_changed)
        row1.addWidget(self.cb_soft_len)
        row1.addSpacing(16)

        row1.addWidget(QLabel("显示:"))
        self.chk_ch = {}
        for name in ("V3", "V4", "V5", "V6"):
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

        row2 = QHBoxLayout()
        self.lbl_trig_src = QLabel("触发源:")
        row2.addWidget(self.lbl_trig_src)
        self.cb_trig_src = QComboBox()
        for text, val in TRIG_SRC_ITEMS:
            self.cb_trig_src.addItem(text, val)
        self.cb_trig_src.currentIndexChanged.connect(self._on_cfg_changed)
        row2.addWidget(self.cb_trig_src)

        self.lbl_trig_edge = QLabel("边沿:")
        row2.addWidget(self.lbl_trig_edge)
        self.cb_trig_edge = QComboBox()
        for text, val in TRIG_EDGE_ITEMS:
            self.cb_trig_edge.addItem(text, val)
        self.cb_trig_edge.currentIndexChanged.connect(self._on_cfg_changed)
        row2.addWidget(self.cb_trig_edge)

        self.lbl_sweep = QLabel("扫描:")
        row2.addWidget(self.lbl_sweep)
        self.cb_sweep = QComboBox()
        for text, val in TRIG_SWEEP_ITEMS:
            self.cb_sweep.addItem(text, val)
        self.cb_sweep.currentIndexChanged.connect(self._on_cfg_changed)
        row2.addWidget(self.cb_sweep)

        self.lbl_level = QLabel("电平 (V):")
        row2.addWidget(self.lbl_level)
        self.ed_level = QLineEdit("0.000")
        self.ed_level.setFixedWidth(70)
        self.ed_level.setAlignment(Qt.AlignCenter)
        self.ed_level.editingFinished.connect(self._on_level_edited)
        row2.addWidget(self.ed_level)
        row2.addSpacing(16)

        self.lbl_status = QLabel("已停止")
        self.lbl_status.setStyleSheet("color:#aaa;")
        row2.addWidget(self.lbl_status)
        row2.addStretch()
        root.addLayout(row2)

        self.plot = pg.PlotWidget()
        self.plot.showGrid(x=True, y=True, alpha=0.3)
        self.plot.setLabel("bottom", "时间", units="s")
        self.plot.setLabel("left", "电压", units="V")
        self.plot.addLegend(offset=(10, 10), labelTextSize="9pt")
        self.plot.setAntialiasing(False)
        self.curves = {
            name: self.plot.plot(pen=pg.mkPen(CH_COLORS[name], width=1.2), name=name)
            for name in ("V3", "V4", "V5", "V6")
        }
        self.line_t0 = pg.InfiniteLine(pos=0, angle=90,
                                       pen=pg.mkPen("#888", style=Qt.DashLine))
        self.plot.addItem(self.line_t0)
        self.line_level = pg.InfiniteLine(pos=0.0, angle=0, movable=True,
                                          pen=pg.mkPen("#f66", style=Qt.DashLine))
        self.line_level.sigPositionChangeFinished.connect(self._on_level_dragged)
        self.plot.addItem(self.line_level)
        root.addWidget(self.plot, 1)

        meas = QGridLayout()
        meas.setHorizontalSpacing(12)
        style = ("background:#1a1a1a; padding:2px 6px; "
                 "font-family:Consolas, monospace; font-size:9pt;")
        self.lbl_meas = {}
        for r, name in enumerate(("V3", "V4", "V5", "V6")):
            lbl = QLabel(f"{name} │ ---")
            lbl.setStyleSheet(f"color:{CH_COLORS[name]}; {style}")
            lbl.setTextInteractionFlags(Qt.TextSelectableByMouse)
            meas.addWidget(lbl, r, 0)
            self.lbl_meas[name] = lbl
        self.lbl_phase = QLabel("相位差: ---")
        self.lbl_phase.setStyleSheet(f"color:#ddd; {style}")
        meas.addWidget(self.lbl_phase, 4, 0)
        frame = QFrame()
        frame.setLayout(meas)
        root.addWidget(frame)
        self._apply_yrange()

    def _is_soft(self) -> bool:
        return self._mode == MODE_SOFT345

    def _on_mode_changed(self, *_):
        was_running = self._running or self._waiting
        self.stop()
        self._mode = self.cb_mode.currentData()
        self._apply_mode_ui()
        if was_running:
            self._start(continuous=True)

    def _apply_mode_ui(self):
        soft = self._is_soft()
        for name, chk in self.chk_ch.items():
            vis = name in ("V3", "V4", "V5") if soft else name in ("V5", "V6")
            chk.setVisible(vis)
            chk.setChecked(vis)
            self.curves[name].setVisible(vis and chk.isChecked())
            self.lbl_meas[name].setVisible(vis)
        self.lbl_timebase.setVisible(not soft)
        self.cb_timebase.setVisible(not soft)
        self.lbl_soft_len.setVisible(soft)
        self.cb_soft_len.setVisible(soft)
        for w in (self.lbl_trig_src, self.cb_trig_src, self.lbl_trig_edge,
                  self.cb_trig_edge, self.lbl_sweep, self.cb_sweep,
                  self.lbl_level, self.ed_level):
            w.setVisible(not soft)
        self.line_level.setVisible(not soft)
        self.btn_single.setEnabled(not soft)
        self.plot.setLabel(
            "bottom",
            "时间 (滚动, 相对最新)" if soft else "时间 (相对触发点)",
            units="s")
        self.lbl_phase.setText(
            "软画模式无硬件触发/相位差" if soft else "V6 相对 V5 相位差: ---")
        self._x_key = None

    def _on_soft_len_changed(self, *_):
        n = int(self.cb_soft_len.currentData())
        for k in list(self._soft_buf.keys()):
            self._soft_buf[k] = deque(self._soft_buf[k], maxlen=n)

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
        if self._is_soft():
            return
        decim = self.cb_timebase.currentData()
        code = int(round(self._level_v() / SCOPE_V_PER_LSB))
        code = max(-32768, min(32767, code))
        self.dev.send_command(f"SDEC:{decim}", quiet=True)
        self.dev.send_command(f"STLV:{code + 32768}", quiet=True)

    def _enter_soft_stream(self) -> bool:
        if not hasattr(self.dev, "set_stream_kind"):
            self.lbl_status.setText("当前设备不支持 SDKOUT")
            return False
        ok = self.dev.set_stream_kind("sdk", quiet=False)
        self._soft_active = bool(ok)
        return ok

    def _leave_soft_stream(self):
        if not self._soft_active:
            return
        if self.dev.is_streaming and hasattr(self.dev, "set_stream_kind"):
            self.dev.set_stream_kind("xy", quiet=False)
        self._soft_active = False

    def _arm(self):
        if self._is_soft():
            return
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

        if self._is_soft():
            for k in self._soft_buf:
                self._soft_buf[k].clear()
            self._soft_n = 0
            self._soft_t0 = time.time()
            if not self._enter_soft_stream():
                self._stop()
                return
            self._soft_timer.start()
            self.lbl_status.setText("SDKOUT 软画中… (主窗口 XYOUT 已暂停)")
            return

        self._leave_soft_stream()
        self._send_cfg()
        self._arm()
        self.lbl_status.setText("等待触发…")

    def _stop(self):
        self._running = False
        self._waiting = False
        self.btn_run.setChecked(False)
        self.btn_run.setText("▶ 运行")
        self._soft_timer.stop()
        self._leave_soft_stream()

    def stop(self):
        self._stop()
        self.lbl_status.setText("已停止")

    def _on_run_clicked(self, checked: bool):
        if checked:
            self._start(continuous=True)
        else:
            self.stop()

    def _on_single_clicked(self):
        if self._is_soft():
            self.lbl_status.setText("软画模式无「单次」, 请用运行")
            return
        self._start(continuous=False)

    def _on_cfg_changed(self, *_):
        if self._is_soft():
            return
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
            if chk.isVisible():
                self.curves[name].setVisible(chk.isChecked())

    def _apply_yrange(self, *_):
        r = self.cb_yrange.currentData()
        if r is None:
            self.plot.enableAutoRange(axis="y")
        else:
            self.plot.setYRange(-r, r, padding=0.02)

    def _on_watchdog(self):
        if self._is_soft():
            if self._running and not self.dev.is_streaming:
                self.stop()
                self.lbl_status.setText("数据流已停止")
            return
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

    def on_scope_packet(self, pkt: dict):
        if self._is_soft() or not self._waiting:
            return
        self._waiting = False
        now = time.time()
        self._pkt_times = [t for t in self._pkt_times if now - t < 2.0] + [now]

        n, pre, dt = pkt["n"], pkt["pre"], pkt["dt"]
        t = (np.arange(n) - pre) * dt
        volts = {"V5": pkt["a"] * SCOPE_V_PER_LSB, "V6": pkt["b"] * SCOPE_V_PER_LSB}
        for name in ("V3", "V4"):
            self.curves[name].setData([], [])
        for name, v in volts.items():
            if self.chk_ch[name].isChecked():
                self.curves[name].setData(t, v)
            self._update_meas(name, v, dt)
        self._update_delay(volts["V5"], volts["V6"], dt)
        x_key = (n, pre, dt)
        if x_key != self._x_key:
            self._x_key = x_key
            self.plot.setXRange(t[0], t[-1], padding=0)

        trig = "自由运行" if pkt["mode"] == 0 else (
            "自动 (未触发)" if pkt["forced"] else "已触发")
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
        if self._running and not self._waiting and not self._is_soft():
            self._arm()

    def on_sdk_frame(self, fr: dict):
        if not self._is_soft() or not self._running:
            return
        self._soft_buf["V3"].append(fr["v3"] * SCOPE_V_PER_LSB)
        self._soft_buf["V4"].append(fr["v4"] * SCOPE_V_PER_LSB)
        self._soft_buf["V5"].append(fr["v5"] * SCOPE_V_PER_LSB)
        self._soft_buf["cnt"].append(fr["sample_cnt"])
        self._soft_n += 1

    def _refresh_soft_plot(self):
        if not self._is_soft() or not self._running:
            return
        n_want = int(self.cb_soft_len.currentData())
        n = len(self._soft_buf["V5"])
        if n < 8:
            self.lbl_status.setText(f"SDKOUT 收集中… {n}/{n_want}")
            return
        cnt = np.fromiter(self._soft_buf["cnt"], dtype=np.uint32, count=n)
        dcnt = np.diff(cnt.astype(np.int64))
        dcnt = dcnt[dcnt > 0]
        dt = float(np.median(dcnt)) * SAMPLE_TICK_S if dcnt.size else (1.0 / 2000.0)
        t = (np.arange(n) - (n - 1)) * dt
        for name in ("V3", "V4", "V5"):
            v = np.fromiter(self._soft_buf[name], dtype=np.float64, count=n)
            if self.chk_ch[name].isChecked():
                self.curves[name].setData(t, v)
            self._update_meas(name, v, dt)
        self.curves["V6"].setData([], [])
        self.lbl_phase.setText("软画模式: V3/V4/V5 (无硬件触发)")

        x_key = (n, round(dt, 12))
        if x_key != self._x_key:
            self._x_key = x_key
            self.plot.setXRange(t[0], t[-1], padding=0)

        now = time.time()
        self._pkt_times = [t0 for t0 in self._pkt_times if now - t0 < 2.0] + [now]
        rate = (len(self._pkt_times) - 1) / (self._pkt_times[-1] - self._pkt_times[0]) \
            if len(self._pkt_times) > 1 else 0.0
        elapsed = max(now - self._soft_t0, 1e-3)
        fps = self._soft_n / elapsed
        self.lbl_status.setText(
            f"SDKOUT 软画   点间隔 ~{_fmt_time(dt)}   到达 ~{fps:.0f} 帧/s   "
            f"刷新 {rate:.1f}/s   缓冲 {n}")

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
        fa, fb = estimate_freq(a, dt), estimate_freq(b, dt)
        if not fa or not fb or abs(fa - fb) > 0.02 * fa:
            self.lbl_phase.setText("V6 相对 V5 相位差: --- (两路频率不同)")
            return
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
