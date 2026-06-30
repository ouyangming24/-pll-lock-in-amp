#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""光弹应力公式 — 独立小 GUI (验算用).

启动:
  python stress_manual_gui.py
  python stress_manual.py --gui
"""

from __future__ import annotations

import sys

from PyQt5.QtCore import Qt
from PyQt5.QtGui import QFont
from PyQt5.QtWidgets import (
    QApplication,
    QCheckBox,
    QGridLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QPlainTextEdit,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from stress_calc import compute_stress
from stress_manual import (
    ROW_LABELS,
    default_calib_field_values,
    default_field_values,
    example_field_values,
    format_stress_report,
    inputs_from_fields,
)


class StressManualWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("光弹应力公式验算")
        self.setMinimumSize(720, 640)
        self.resize(780, 720)

        self._edits: dict[str, QLineEdit] = {}
        self._calib_edits: dict[str, QLineEdit] = {}
        self._r_labels: dict[str, QLabel] = {}

        root = QWidget()
        self.setCentralWidget(root)
        layout = QVBoxLayout(root)
        layout.setSpacing(8)
        layout.setContentsMargins(10, 10, 10, 10)

        hint = QLabel(
            "输入四路电压: 振荡器1(2F1+F2) / 2(F1+2F2) / 3(F1+F2) 谐波为 V_rms, 直流为 V.\n"
            "X<0 时 R1/R2/R3 取负. R3_fix=R3_o/R3_off; R1/2_fix=(R_o-R_off)/R3_off.\n"
            "公式同 1119修正计算公式.md / stress_calc.py."
        )
        hint.setWordWrap(True)
        hint.setStyleSheet("color: #8ad; font-size: 10pt;")
        layout.addWidget(hint)

        row_opts = QHBoxLayout()
        self.chk_r_mode = QCheckBox("R 模式 (仅填 X=带符号 R, Y 忽略)")
        self.chk_r_mode.toggled.connect(self._on_r_mode_toggled)
        row_opts.addWidget(self.chk_r_mode)
        row_opts.addStretch()
        layout.addLayout(row_opts)

        layout.addWidget(self._build_table_group(
            "测量值 (样品)", "meas", ("0", "0", "0", "0", "0", "0", "0")))
        layout.addWidget(self._build_table_group(
            "空气基准 Offset", "off", ("0", "0", "0", "0", "0", "0", "0")))
        layout.addWidget(self._build_calib_group())

        btn_h = QHBoxLayout()
        btn_ex = QPushButton("载入文档示例")
        btn_ex.clicked.connect(self._load_example)
        btn_calc = QPushButton("计算")
        btn_calc.setStyleSheet(
            "background:#536; color:#fff; font-weight:bold; padding:6px 16px;")
        btn_calc.clicked.connect(self._on_calculate)
        btn_clear = QPushButton("清空")
        btn_clear.clicked.connect(self._clear_fields)
        btn_h.addWidget(btn_ex)
        btn_h.addWidget(btn_calc)
        btn_h.addWidget(btn_clear)
        btn_h.addStretch()
        layout.addLayout(btn_h)

        self.lbl_summary = QLabel("rho = --- deg     delta = --- nm")
        self.lbl_summary.setStyleSheet(
            "font-family: Consolas; font-size: 12pt; color: #6f6; padding: 4px;")
        layout.addWidget(self.lbl_summary)

        self.txt_report = QPlainTextEdit()
        self.txt_report.setReadOnly(True)
        self.txt_report.setFont(QFont("Consolas", 9))
        self.txt_report.setPlaceholderText("点击「计算」显示完整中间步骤…")
        layout.addWidget(self.txt_report, 1)

        self._apply_style()
        self.chk_r_mode.setChecked(True)
        self._load_default_init()

    def _load_default_init(self) -> None:
        self._set_fields(default_field_values())
        self._on_calculate()

    def _apply_style(self) -> None:
        self.setStyleSheet("""
            QWidget { background: #2a2a2a; color: #ddd;
                      font-family: 'Microsoft YaHei UI'; font-size: 10pt; }
            QGroupBox { border: 1px solid #666; border-radius: 4px;
                        margin-top: 10px; padding-top: 8px; }
            QGroupBox::title { subcontrol-origin: margin; left: 8px;
                               padding: 0 4px; color: #c8f; font-weight: bold; }
            QLineEdit { background: #1e1e1e; border: 1px solid #555;
                        border-radius: 3px; padding: 4px; }
            QPushButton { background: #444; border: 1px solid #666;
                          border-radius: 3px; padding: 4px 10px; }
            QPushButton:hover { background: #555; }
            QPlainTextEdit { background: #111; color: #aea; border: 1px solid #444; }
        """)

    def _build_table_group(
        self, title: str, prefix: str, defaults: tuple[str, ...]
    ) -> QGroupBox:
        gb = QGroupBox(title)
        grid = QGridLayout(gb)
        grid.setHorizontalSpacing(8)
        grid.setVerticalSpacing(6)

        grid.addWidget(QLabel(""), 0, 0)
        hdr_x = QLabel("X (V)")
        hdr_x.setStyleSheet("color: #8ad;")
        hdr_y = QLabel("Y (V)")
        hdr_y.setStyleSheet("color: #8ad;")
        hdr_r = QLabel("signed R")
        hdr_r.setStyleSheet("color: #888; font-size: 9pt;")
        grid.addWidget(hdr_x, 0, 1)
        grid.addWidget(hdr_y, 0, 2)
        grid.addWidget(hdr_r, 0, 3)

        di = 0
        for i, (key, label) in enumerate(ROW_LABELS):
            grid.addWidget(QLabel(label), i + 1, 0)
            ex = QLineEdit(defaults[di])
            ex.setAlignment(Qt.AlignCenter)
            ey = QLineEdit(defaults[di + 1])
            ey.setAlignment(Qt.AlignCenter)
            grid.addWidget(ex, i + 1, 1)
            grid.addWidget(ey, i + 1, 2)
            lbl_r = QLabel("---")
            lbl_r.setAlignment(Qt.AlignCenter)
            lbl_r.setStyleSheet("font-family: Consolas; color: #9a9;")
            grid.addWidget(lbl_r, i + 1, 3)
            self._edits[f"{prefix}_{key}_x"] = ex
            self._edits[f"{prefix}_{key}_y"] = ey
            self._r_labels[f"{prefix}_{key}"] = lbl_r
            ex.textChanged.connect(lambda _t, p=prefix, k=key: self._update_signed_r(p, k))
            ey.textChanged.connect(lambda _t, p=prefix, k=key: self._update_signed_r(p, k))
            di += 2

        grid.addWidget(QLabel("直流 V_DC (V)"), 4, 0)
        ed_dc = QLineEdit(defaults[6])
        ed_dc.setAlignment(Qt.AlignCenter)
        grid.addWidget(ed_dc, 4, 1, 1, 2)
        self._edits[f"{prefix}_vdc"] = ed_dc
        return gb

    def _build_calib_group(self) -> QGroupBox:
        gb = QGroupBox("校正系数 K (测量与 Offset 同乘)")
        h = QHBoxLayout(gb)
        h.setSpacing(8)
        for key, label in (
            ("osc1", "振荡器1"), ("osc2", "振荡器2"),
            ("osc3", "振荡器3"), ("dc", "直流"),
        ):
            h.addWidget(QLabel(label))
            ed = QLineEdit("1")
            ed.setFixedWidth(64)
            ed.setAlignment(Qt.AlignCenter)
            self._calib_edits[f"calib_{key}"] = ed
            h.addWidget(ed)
        h.addStretch()
        return gb

    def _update_signed_r(self, prefix: str, key: str) -> None:
        from stress_calc import signed_r
        lbl = self._r_labels.get(f"{prefix}_{key}")
        ex = self._edits.get(f"{prefix}_{key}_x")
        ey = self._edits.get(f"{prefix}_{key}_y")
        if lbl is None or ex is None or ey is None:
            return
        try:
            x = float(ex.text().strip() or "0")
            y = 0.0 if self.chk_r_mode.isChecked() else float(ey.text().strip() or "0")
            r = signed_r(x, y)
            lbl.setText(f"{r:+.5f}")
        except ValueError:
            lbl.setText("---")

    def _on_r_mode_toggled(self, checked: bool) -> None:
        for prefix in ("meas", "off"):
            for key, _ in ROW_LABELS:
                ey = self._edits.get(f"{prefix}_{key}_y")
                if isinstance(ey, QLineEdit):
                    ey.setEnabled(not checked)
                self._update_signed_r(prefix, key)

    def _collect_fields(self) -> dict[str, str]:
        fields = {k: w.text() for k, w in self._edits.items()}
        fields.update({k: w.text() for k, w in self._calib_edits.items()})
        return fields

    def _set_fields(self, fields: dict[str, str]) -> None:
        for k, v in fields.items():
            w = self._edits.get(k) or self._calib_edits.get(k)
            if w is not None:
                w.setText(v)
        for prefix in ("meas", "off"):
            for key, _ in ROW_LABELS:
                self._update_signed_r(prefix, key)

    def _load_example(self) -> None:
        self._set_fields(example_field_values())
        self._on_calculate()

    def _clear_fields(self) -> None:
        zeros = {k: "0" for k in self._edits}
        zeros.update(default_calib_field_values())
        self._set_fields(zeros)
        self.lbl_summary.setText("rho = --- deg     delta = --- nm")
        self.txt_report.clear()

    def _on_calculate(self) -> None:
        fields = self._collect_fields()
        inp, err = inputs_from_fields(fields, self.chk_r_mode.isChecked())
        if err or inp is None:
            self.lbl_summary.setText(f"[!] {err}")
            self.txt_report.setPlainText(err or "输入错误")
            return
        res = compute_stress(inp)
        if res.ok:
            self.lbl_summary.setText(
                f"rho = {res.rho_deg:+.4f} deg     delta = {res.delta_nm:.4f} nm")
        else:
            self.lbl_summary.setText(f"[!] {res.message}")
        self.txt_report.setPlainText(format_stress_report(inp, res))


def main() -> int:
    app = QApplication(sys.argv)
    win = StressManualWindow()
    win.show()
    return app.exec_()


if __name__ == "__main__":
    sys.exit(main())
