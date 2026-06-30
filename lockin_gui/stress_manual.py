#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""光弹应力公式 — 手动验算 (CLI + 共享逻辑).

与 GUI 共用 lockin_gui/stress_calc.py.

用法:
  python stress_manual.py              # 命令行交互
  python stress_manual.py --example    # CLI 载入文档示例
  python stress_manual.py --gui        # 打开小窗口 GUI
  python stress_manual_gui.py          # 同上
"""

from __future__ import annotations

import argparse
import math
import sys

from stress_calc import (
    J1_DELTA0,
    J2_DELTA0,
    ChannelVoltages,
    StressCalib,
    StressInputs,
    StressResult,
    apply_stress_calib,
    compute_stress,
    format_stress_report,
    signed_r,
    stress_constants_text,
)

# 通道标签 (GUI / CLI 共用)
ROW_LABELS = (
    ("osc1", "振荡器1 (2F1+F2)"),
    ("osc2", "振荡器2 (F1+2F2)"),
    ("osc3", "振荡器3 (F1+F2)"),
)

_PEAK_TO_RMS = 1.0 / math.sqrt(2.0)


def _harm_v_rms(v_peak: float) -> float:
    """谐波电压: 峰值 → V_rms (应力公式用)."""
    return v_peak * _PEAK_TO_RMS


def load_example() -> StressInputs:
    """1119修正计算公式.md 中的 Origin + Offset 表格 (谐波 X 转为 V_rms)."""
    return StressInputs(
        osc1=ChannelVoltages(_harm_v_rms(-0.03807), 0.0),
        osc2=ChannelVoltages(_harm_v_rms(-0.186), 0.0),
        osc3=ChannelVoltages(_harm_v_rms(-0.03467), 0.0),
        v_dc=0.572891,
        offset1=ChannelVoltages(_harm_v_rms(-0.00322), 0.0),
        offset2=ChannelVoltages(_harm_v_rms(0.006021), 0.0),
        offset3=ChannelVoltages(_harm_v_rms(0.277444), 0.0),
        v_dc_offset=0.693512,
    )


def load_default_init() -> StressInputs:
    """上板实测初值 (R 模式: X = 带符号 R, Y=0, 与 GUI 读数一致)."""
    return StressInputs(
        osc1=ChannelVoltages(-6270.0, 0.0),
        osc2=ChannelVoltages(-91280.0, 0.0),
        osc3=ChannelVoltages(45910.0, 0.0),
        v_dc=476460.0,
        offset1=ChannelVoltages(1260.0, 0.0),
        offset2=ChannelVoltages(-3210.0, 0.0),
        offset3=ChannelVoltages(128000.0, 0.0),
        v_dc_offset=584000.0,
    )


def _inputs_to_field_values(ex: StressInputs) -> dict[str, str]:
    return {
        "meas_osc1_x": f"{ex.osc1.x}",
        "meas_osc1_y": f"{ex.osc1.y}",
        "meas_osc2_x": f"{ex.osc2.x}",
        "meas_osc2_y": f"{ex.osc2.y}",
        "meas_osc3_x": f"{ex.osc3.x}",
        "meas_osc3_y": f"{ex.osc3.y}",
        "meas_vdc": f"{ex.v_dc}",
        "off_osc1_x": f"{ex.offset1.x}",
        "off_osc1_y": f"{ex.offset1.y}",
        "off_osc2_x": f"{ex.offset2.x}",
        "off_osc2_y": f"{ex.offset2.y}",
        "off_osc3_x": f"{ex.offset3.x}",
        "off_osc3_y": f"{ex.offset3.y}",
        "off_vdc": f"{ex.v_dc_offset}",
        **default_calib_field_values(),
    }


def default_field_values() -> dict[str, str]:
    """GUI 启动默认表单 (实测初值)."""
    return _inputs_to_field_values(load_default_init())


def example_field_values() -> dict[str, str]:
    """文档示例 → 表单字符串 (meas_* / off_*)."""
    return _inputs_to_field_values(load_example())


def default_calib_field_values() -> dict[str, str]:
    return {
        "calib_osc1": "1",
        "calib_osc2": "1",
        "calib_osc3": "1",
        "calib_dc": "1",
    }


def parse_calib_from_fields(fields: dict[str, str]) -> tuple[StressCalib | None, str | None]:
    k1, err = _parse_float(fields.get("calib_osc1", "1"), "K 振荡器1")
    if err:
        return None, err
    k2, err = _parse_float(fields.get("calib_osc2", "1"), "K 振荡器2")
    if err:
        return None, err
    k3, err = _parse_float(fields.get("calib_osc3", "1"), "K 振荡器3")
    if err:
        return None, err
    kd, err = _parse_float(fields.get("calib_dc", "1"), "K 直流")
    if err:
        return None, err
    return StressCalib(k1, k2, k3, kd), None


def _parse_float(text: str, name: str) -> tuple[float | None, str | None]:
    text = text.strip()
    if not text:
        return None, f"{name} 不能为空"
    try:
        return float(text), None
    except ValueError:
        return None, f"{name} 非法: {text!r}"


def _read_channel(
    fields: dict[str, str],
    prefix: str,
    label: str,
    r_mode: bool,
) -> tuple[ChannelVoltages | None, str | None]:
    x, err = _parse_float(fields.get(f"{prefix}_x", ""), f"{label} X")
    if err:
        return None, err
    if r_mode:
        return ChannelVoltages(x, 0.0), None
    y, err = _parse_float(fields.get(f"{prefix}_y", ""), f"{label} Y")
    if err:
        return None, err
    return ChannelVoltages(x, y), None


def inputs_from_fields(fields: dict[str, str], r_mode: bool = False) -> tuple[StressInputs | None, str | None]:
    """从表单字段 dict 构建 StressInputs; 失败时返回错误信息."""
    osc1, err = _read_channel(fields, "meas_osc1", "测量 Osc1", r_mode)
    if err:
        return None, err
    osc2, err = _read_channel(fields, "meas_osc2", "测量 Osc2", r_mode)
    if err:
        return None, err
    osc3, err = _read_channel(fields, "meas_osc3", "测量 Osc3", r_mode)
    if err:
        return None, err
    v_dc, err = _parse_float(fields.get("meas_vdc", ""), "测量 V_DC")
    if err:
        return None, err

    off1, err = _read_channel(fields, "off_osc1", "Offset Osc1", r_mode)
    if err:
        return None, err
    off2, err = _read_channel(fields, "off_osc2", "Offset Osc2", r_mode)
    if err:
        return None, err
    off3, err = _read_channel(fields, "off_osc3", "Offset Osc3", r_mode)
    if err:
        return None, err
    v_dc_off, err = _parse_float(fields.get("off_vdc", ""), "Offset V_DC")
    if err:
        return None, err

    calib, err = parse_calib_from_fields(fields)
    if err:
        return None, err

    return StressInputs(
        osc1=osc1, osc2=osc2, osc3=osc3, v_dc=v_dc,
        offset1=off1, offset2=off2, offset3=off3,
        v_dc_offset=v_dc_off,
        calib=calib,
    ), None


# constants_text / format_stress_report 见 stress_calc.py
constants_text = stress_constants_text


# ── CLI ─────────────────────────────────────────────────────────────

def _prompt_float(label: str, default: float | None = None) -> float:
    hint = f" [{default}]" if default is not None else ""
    while True:
        raw = input(f"  {label}{hint}: ").strip()
        if raw == "" and default is not None:
            return default
        try:
            return float(raw)
        except ValueError:
            print("    [!] 请输入数字")


def _prompt_xy_or_r(r_mode: bool, prefix: str) -> ChannelVoltages:
    print(f"\n--- {prefix} ---")
    if r_mode:
        r = _prompt_float("带符号 R (V_rms), X<0 时为负")
        return ChannelVoltages(r, 0.0)
    x = _prompt_float("X (V_rms)")
    y = _prompt_float("Y (V_rms)")
    r = signed_r(x, y)
    print(f"    -> signed R = {r:+.6f} V")
    return ChannelVoltages(x, y)


def _read_interactive(r_mode: bool) -> StressInputs:
    print("\n===== 测量值 (样品) =====")
    osc1 = _prompt_xy_or_r(r_mode, "振荡器1  (2F1+F2)")
    osc2 = _prompt_xy_or_r(r_mode, "振荡器2  (F1+2F2)")
    osc3 = _prompt_xy_or_r(r_mode, "振荡器3  (F1+F2)")
    v_dc = _prompt_float("直流 V_DC (V)")
    print("\n===== 空气基准 Offset =====")
    off1 = _prompt_xy_or_r(r_mode, "Offset 振荡器1")
    off2 = _prompt_xy_or_r(r_mode, "Offset 振荡器2")
    off3 = _prompt_xy_or_r(r_mode, "Offset 振荡器3")
    v_dc_off = _prompt_float("Offset 直流 V_DC (V)")
    return StressInputs(
        osc1=osc1, osc2=osc2, osc3=osc3, v_dc=v_dc,
        offset1=off1, offset2=off2, offset3=off3,
        v_dc_offset=v_dc_off,
    )


def run_cli(example: bool, r_mode: bool) -> int:
    print("=" * 60)
    print("  光弹应力公式验算 (CLI)")
    print("=" * 60)
    print(constants_text())
    inp = load_example() if example else _read_interactive(r_mode)
    if example:
        print("\n[*] 已载入文档示例数据")
    res = compute_stress(inp)
    print(format_stress_report(inp, res))
    print("=" * 60)
    return 0 if res.ok else 1


def run_gui() -> int:
    from stress_manual_gui import main as gui_main
    return gui_main()


def main() -> int:
    parser = argparse.ArgumentParser(description="光弹应力公式手动验算")
    parser.add_argument("--example", action="store_true", help="CLI: 文档示例")
    parser.add_argument("--r-mode", action="store_true", help="CLI: 直接输入 R")
    parser.add_argument("--gui", action="store_true", help="打开小窗口 GUI")
    args = parser.parse_args()
    if args.gui:
        return run_gui()
    return run_cli(args.example, args.r_mode)


if __name__ == "__main__":
    sys.exit(main())
