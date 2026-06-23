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
    signed_r,
)

# 通道标签 (GUI / CLI 共用)
ROW_LABELS = (
    ("osc1", "振荡器1 (2F1+F2)"),
    ("osc2", "振荡器2 (F1+2F2)"),
    ("osc3", "振荡器3 (F1+F2)"),
)


def load_example() -> StressInputs:
    """1119修正计算公式.md 中的 Origin + Offset 表格."""
    return StressInputs(
        osc1=ChannelVoltages(-0.03807, 0.0),
        osc2=ChannelVoltages(-0.186, 0.0),
        osc3=ChannelVoltages(-0.03467, 0.0),
        v_dc=0.572891,
        offset1=ChannelVoltages(-0.00322, 0.0),
        offset2=ChannelVoltages(0.006021, 0.0),
        offset3=ChannelVoltages(0.277444, 0.0),
        v_dc_offset=0.693512,
    )


def load_default_init() -> StressInputs:
    """上板实测初值 (R 模式: X = 带符号 R, GUI 默认载入)."""
    return StressInputs(
        osc1=ChannelVoltages(-55700.936, 0.0),
        osc2=ChannelVoltages(-28977.0043, 0.0),
        osc3=ChannelVoltages(-108385.0650, 0.0),
        v_dc=591575.3070,
        offset1=ChannelVoltages(1137.4862, 0.0),
        offset2=ChannelVoltages(-3123.8179, 0.0),
        offset3=ChannelVoltages(131117.5430, 0.0),
        v_dc_offset=597528.7470,
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


def constants_text() -> str:
    return (
        f"J1(2.405) = {J1_DELTA0}    J2(2.405) = {J2_DELTA0}\n"
        f"分母 R1/R2: 4*J2*J1 = {4 * J2_DELTA0 * J1_DELTA0:.6f}\n"
        f"分母 R3:    4*J1*J1 = {4 * J1_DELTA0 * J1_DELTA0:.6f}\n"
        f"delta(nm) = delta(rad) * {316.4 / math.pi:.6f}"
    )


def format_stress_report(inp: StressInputs, res: StressResult) -> str:
    """完整验算报告 (CLI / GUI 结果区)."""
    c = inp.calib
    scaled = apply_stress_calib(inp)
    v1 = signed_r(scaled.osc1.x, scaled.osc1.y)
    v2 = signed_r(scaled.osc2.x, scaled.osc2.y)
    v3 = signed_r(scaled.osc3.x, scaled.osc3.y)
    o1 = signed_r(scaled.offset1.x, scaled.offset1.y)
    o2 = signed_r(scaled.offset2.x, scaled.offset2.y)
    o3 = signed_r(scaled.offset3.x, scaled.offset3.y)

    lines = [
        "=== 常数 ===",
        constants_text(),
        "",
        "=== 校正系数 K (测量与 Offset 同乘) ===",
        f"  K_osc1={c.k_osc1:g}  K_osc2={c.k_osc2:g}  "
        f"K_osc3={c.k_osc3:g}  K_dc={c.k_dc:g}",
        "",
        "=== 带符号谐波幅值 (校正后 V) ===",
        f"  测量  Osc1: {v1:+.6f}   Osc2: {v2:+.6f}   "
        f"Osc3: {v3:+.6f}   V_DC: {scaled.v_dc:.6f}",
        f"  Offset Osc1: {o1:+.6f}   Osc2: {o2:+.6f}   "
        f"Osc3: {o3:+.6f}   V_DC: {scaled.v_dc_offset:.6f}",
        "",
        "=== 式 8.1-8.3  R_origin / R_offset ===",
        f"  R1_origin = {res.r1_origin:+.8f}    R1_offset = {res.r1_offset:+.8f}",
        f"  R2_origin = {res.r2_origin:+.8f}    R2_offset = {res.r2_offset:+.8f}",
        f"  R3_origin = {res.r3_origin:+.8f}    R3_offset = {res.r3_offset:+.8f}",
        "",
        "=== Offset 修正 (R1/R2/R3_fix = R_origin / R3_offset) ===",
        f"  R1_fix = R1_origin / R3_offset = {res.r1_fix:+.8f}",
        f"  R2_fix = R2_origin / R3_offset = {res.r2_fix:+.8f}",
        f"  R3_fix = R3_origin / R3_offset = {res.r3_fix:+.8f}",
        "",
        "=== 式 9.1-9.2  结果 ===",
    ]
    if res.ok:
        lines.append(f"  rho   = {res.rho_deg:+.6f} deg  (0.5*atan2(R2,R1))")
        lines.append(f"  delta = {res.delta_nm:.6f} nm  ({res.delta_rad:.8f} rad)")
        if abs(res.r3_fix) <= 1.0:
            lines.append(
                f"  (对照 acos R3) delta = {math.degrees(math.acos(max(-1.0, min(1.0, res.r3_fix)))):.4f} deg"
            )
    else:
        lines.append(f"  [!] {res.message}")
    return "\n".join(lines)


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
        r = _prompt_float("带符号 R (V), X<0 时为负")
        return ChannelVoltages(r, 0.0)
    x = _prompt_float("X (V)")
    y = _prompt_float("Y (V)")
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
