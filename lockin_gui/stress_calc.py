"""光弹法应力计算 — 由锁相四路电压 (振荡器1/2/3 + 直流) 求 ρ、δ.

公式来源: 1119修正计算公式.md (式 8.1–8.2–8.3, 9.1–9.2).

通道对应:
  振荡器1 (2F1+F2) → V_{2e1+e2} → R1
  振荡器2 (F1+2F2) → V_{e1+2e2} → R2
  振荡器3 (F1+F2)  → V_{e1+e2}  → R3
  直流             → V_DC

电压单位: 谐波 X/Y 为 **V_rms** (FPGA 峰值读数 ÷ √2); 直流 V_DC 为 DC 均值 (不除 √2).

符号: 式 8.x 先用 |X+jY| 代入, 若 X < 0 则 R1/R2/R3 取负 (与文档 LIA 表格一致).
Offset 修正: R3_fix = R3_origin / R3_offset;
             R1_fix = (R1_origin - R1_offset) / R3_offset,
             R2_fix = (R2_origin - R2_offset) / R3_offset.
校正: 代入公式前 V' = K × V; 振荡器1/2/3 各一路 K, 直流单独 K_dc (测量与 Offset 同乘).
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

# 调制深度 δ1_0 = δ2_0 = 2.405 (Bessel 自变量)
DELTA0 = 2.405
J1_DELTA0 = 0.5192   # J1(2.405)
J2_DELTA0 = 0.4318   # J2(2.405)

# 式 8.x 分母: 2·J_a · 2·J_b
_DEN_R1 = 4.0 * J2_DELTA0 * J1_DELTA0   # 2e1+e2
_DEN_R2 = 4.0 * J2_DELTA0 * J1_DELTA0   # e1+2e2
_DEN_R3 = 4.0 * J1_DELTA0 * J1_DELTA0   # e1+e2

NM_PER_RAD = 316.4 / math.pi            # δ (rad) → nm


def compute_rho_rad(r1_fix: float, r2_fix: float) -> float:
    """式 9.1: ρ = (1/2) arctan(R2/R1), 实现为 0.5 * atan2(R2, R1)."""
    return 0.5 * math.atan2(r2_fix, r1_fix)
def compute_delta_rad(r1_fix: float, r2_fix: float, r3_fix: float) -> float:
    """式 9.2: δ = atan2(sinδ, cosδ), 其中 sinδ = √(R1²+R2²), cosδ = R3.

    等价于 δ = acos(R3) (当 |R3|≤1 且 sinδ≥0), 但 atan2 在 R3<0 时给出 (π/2, π],
    即 **δ > 90°** 的情况;  plain atan(√(...)) 只能到 90°, 会算错.
    结果归一化到 [0, π] (光弹 retardation 物理范围).
    """
    sin_delta = math.hypot(r1_fix, r2_fix)   # 由 8.1–8.2: R1²+R2² = sin²δ
    delta = math.atan2(sin_delta, r3_fix)
    if delta < 0.0:
        delta += 2.0 * math.pi
    if delta > math.pi:
        # sinδ≥0 时通常不应超过 π; 数值异常时钳到 π
        delta = math.pi
    return delta


@dataclass(frozen=True)
class ChannelVoltages:
    """单路锁相读数 (谐波 X/Y 为 V_rms)."""
    x: float
    y: float
    dc: float | None = None   # 谐波路可选独立 DC; 缺省用公共 v_dc


@dataclass(frozen=True)
class StressCalib:
    """四路校正系数 (默认 1.0)."""
    k_osc1: float = 1.0
    k_osc2: float = 1.0
    k_osc3: float = 1.0
    k_dc: float = 1.0


@dataclass(frozen=True)
class StressInputs:
    """测量值与空气基准 (谐波为 V_rms, 直流为 V)."""
    osc1: ChannelVoltages
    osc2: ChannelVoltages
    osc3: ChannelVoltages
    v_dc: float
    offset1: ChannelVoltages
    offset2: ChannelVoltages
    offset3: ChannelVoltages
    v_dc_offset: float
    calib: StressCalib = field(default_factory=StressCalib)


@dataclass(frozen=True)
class StressResult:
    r1_origin: float
    r2_origin: float
    r3_origin: float
    r1_offset: float
    r2_offset: float
    r3_offset: float
    r1_fix: float
    r2_fix: float
    r3_fix: float
    rho_deg: float
    delta_nm: float
    delta_rad: float
    ok: bool
    message: str = ""


def signed_r(x: float, y: float) -> float:
    """LIA 谐波幅值: |X+jY|, X<0 时取负 (用于显示/报告)."""
    r = math.hypot(x, y)
    return -r if x < 0.0 else r


def compute_r_from_channel(x: float, y: float, v_dc: float, denom: float) -> float:
    """式 8.x: (|V_har|/V_DC)/denom; 若 X<0 则整条 R 取负."""
    if abs(v_dc) < 1e-15:
        return float("nan")
    r = (math.hypot(x, y) / v_dc) / denom
    if x < 0.0:
        r = -r
    return r


def scale_channel(ch: ChannelVoltages, k: float) -> ChannelVoltages:
    """校正系数乘到 X/Y."""
    return ChannelVoltages(ch.x * k, ch.y * k, ch.dc)


def apply_stress_calib(inp: StressInputs) -> StressInputs:
    """测量值与 Offset 按四路 K 缩放后返回新 StressInputs."""
    c = inp.calib
    return StressInputs(
        osc1=scale_channel(inp.osc1, c.k_osc1),
        osc2=scale_channel(inp.osc2, c.k_osc2),
        osc3=scale_channel(inp.osc3, c.k_osc3),
        v_dc=inp.v_dc * c.k_dc,
        offset1=scale_channel(inp.offset1, c.k_osc1),
        offset2=scale_channel(inp.offset2, c.k_osc2),
        offset3=scale_channel(inp.offset3, c.k_osc3),
        v_dc_offset=inp.v_dc_offset * c.k_dc,
        calib=c,
    )


def compute_r1(x: float, y: float, v_dc: float) -> float:
    return compute_r_from_channel(x, y, v_dc, _DEN_R1)


def compute_r2(x: float, y: float, v_dc: float) -> float:
    return compute_r_from_channel(x, y, v_dc, _DEN_R2)


def compute_r3(x: float, y: float, v_dc: float) -> float:
    return compute_r_from_channel(x, y, v_dc, _DEN_R3)


def compute_stress(inp: StressInputs) -> StressResult:
    """完整流程: 校正 → origin → offset 修正 → ρ (°) 与 δ (nm)."""
    inp = apply_stress_calib(inp)

    vdc = inp.v_dc
    vdc_off = inp.v_dc_offset

    r1_o = compute_r1(inp.osc1.x, inp.osc1.y, vdc)
    r2_o = compute_r2(inp.osc2.x, inp.osc2.y, vdc)
    r3_o = compute_r3(inp.osc3.x, inp.osc3.y, vdc)

    r1_f = compute_r1(inp.offset1.x, inp.offset1.y, vdc_off)
    r2_f = compute_r2(inp.offset2.x, inp.offset2.y, vdc_off)
    r3_f = compute_r3(inp.offset3.x, inp.offset3.y, vdc_off)

    if not all(math.isfinite(v) for v in (r1_o, r2_o, r3_o, r1_f, r2_f, r3_f)):
        return StressResult(
            r1_o, r2_o, r3_o, r1_f, r2_f, r3_f,
            float("nan"), float("nan"), float("nan"),
            float("nan"), float("nan"), float("nan"),
            ok=False, message="V_DC 过小或读数无效",
        )

    if abs(r3_f) < 1e-15:
        return StressResult(
            r1_o, r2_o, r3_o, r1_f, r2_f, r3_f,
            float("nan"), float("nan"), float("nan"),
            float("nan"), float("nan"), float("nan"),
            ok=False, message="R3_offset 过小, 无法修正 R1/R2",
        )

    r3_fix = r3_o / r3_f
    r1_fix = (r1_o - r1_f) / r3_f
    r2_fix = (r2_o - r2_f) / r3_f

    rho_rad = compute_rho_rad(r1_fix, r2_fix)
    rho_deg = math.degrees(rho_rad)

    if abs(r3_fix) < 1e-15 and math.hypot(r1_fix, r2_fix) < 1e-15:
        delta_rad = float("nan")
        delta_nm = float("nan")
        msg = "R3_fix 与 R1/R2_fix 过小"
        ok = False
    else:
        delta_rad = compute_delta_rad(r1_fix, r2_fix, r3_fix)
        delta_nm = delta_rad * NM_PER_RAD
        ok = math.isfinite(rho_deg) and math.isfinite(delta_nm)
        msg = "" if ok else "计算结果非有限值"

    return StressResult(
        r1_o, r2_o, r3_o, r1_f, r2_f, r3_f,
        r1_fix, r2_fix, r3_fix,
        rho_deg, delta_nm, delta_rad,
        ok=ok, message=msg,
    )


def stress_constants_text() -> str:
    return (
        f"J1(2.405) = {J1_DELTA0}    J2(2.405) = {J2_DELTA0}\n"
        f"分母 R1/R2 (式8.1/8.2): 4*J2*J1 = {_DEN_R1:.6f}\n"
        f"分母 R3   (式8.3):     4*J1*J1 = {_DEN_R3:.6f}\n"
        f"delta(nm) = delta(rad) * {NM_PER_RAD:.6f}"
    )


def _fmt_ch_line(label: str, ch: ChannelVoltages, v_dc: float | None = None) -> str:
    sr = signed_r(ch.x, ch.y)
    mag = abs(sr)
    line = (
        f"  {label}: X={ch.x:+.6f} V_rms  Y={ch.y:+.6f} V_rms  "
        f"|R|={mag:.6f}  signed_R={sr:+.6f}"
    )
    if v_dc is not None:
        line += f"  V_DC={v_dc:.6f} V"
    return line


def _fmt_r_step(
    name: str, x: float, y: float, v_dc: float, denom: float, r_val: float,
) -> str:
    mag = math.hypot(x, y)
    ratio = mag / v_dc if abs(v_dc) > 1e-15 else float("nan")
    sign = " (X<0 取负)" if x < 0.0 and mag > 0 else ""
    return (
        f"  {name} = (|X+jY|/V_DC) / denom = ({mag:.6f}/{v_dc:.6f}) / {denom:.6f}"
        f" = {ratio:.8f} / {denom:.6f}{sign} = {r_val:+.8f}"
    )


def format_stress_report(inp: StressInputs, res: StressResult) -> str:
    """完整验算报告: 谐波读数 → R → R_fix → rho / delta."""
    c = inp.calib
    scaled = apply_stress_calib(inp)

    lines = [
        "=== 1. 样品测量 (校正前, V_rms / V) ===",
        _fmt_ch_line("振荡器1 (2F1+F2)", inp.osc1, inp.v_dc),
        _fmt_ch_line("振荡器2 (F1+2F2)", inp.osc2),
        _fmt_ch_line("振荡器3 (F1+F2)", inp.osc3),
        "",
        "=== 2. 空气 Offset (校正前) ===",
        _fmt_ch_line("振荡器1", inp.offset1, inp.v_dc_offset),
        _fmt_ch_line("振荡器2", inp.offset2),
        _fmt_ch_line("振荡器3", inp.offset3),
        "",
        "=== 3. 校正系数 K (测量与 Offset 同乘) ===",
        f"  K_osc1={c.k_osc1:g}  K_osc2={c.k_osc2:g}  "
        f"K_osc3={c.k_osc3:g}  K_dc={c.k_dc:g}",
        "",
        "=== 4. 校正后电压 ===",
        _fmt_ch_line("样品 Osc1", scaled.osc1, scaled.v_dc),
        _fmt_ch_line("样品 Osc2", scaled.osc2),
        _fmt_ch_line("样品 Osc3", scaled.osc3),
        _fmt_ch_line("Offset Osc1", scaled.offset1, scaled.v_dc_offset),
        _fmt_ch_line("Offset Osc2", scaled.offset2),
        _fmt_ch_line("Offset Osc3", scaled.offset3),
        "",
        "=== 5. 常数 ===",
        stress_constants_text(),
        "",
        "=== 6. 式 8.1-8.3  R_origin / R_offset ===",
        _fmt_r_step(
            "R1_origin", scaled.osc1.x, scaled.osc1.y, scaled.v_dc, _DEN_R1,
            res.r1_origin,
        ),
        _fmt_r_step(
            "R1_offset", scaled.offset1.x, scaled.offset1.y, scaled.v_dc_offset,
            _DEN_R1, res.r1_offset,
        ),
        _fmt_r_step(
            "R2_origin", scaled.osc2.x, scaled.osc2.y, scaled.v_dc, _DEN_R2,
            res.r2_origin,
        ),
        _fmt_r_step(
            "R2_offset", scaled.offset2.x, scaled.offset2.y, scaled.v_dc_offset,
            _DEN_R2, res.r2_offset,
        ),
        _fmt_r_step(
            "R3_origin", scaled.osc3.x, scaled.osc3.y, scaled.v_dc, _DEN_R3,
            res.r3_origin,
        ),
        _fmt_r_step(
            "R3_offset", scaled.offset3.x, scaled.offset3.y, scaled.v_dc_offset,
            _DEN_R3, res.r3_offset,
        ),
        "",
        "=== 7. Offset 修正 ===",
    ]

    if math.isfinite(res.r3_offset) and abs(res.r3_offset) > 1e-15:
        lines.append(
            f"  R3_fix = R3_origin / R3_offset"
            f" = {res.r3_origin:+.8f} / {res.r3_offset:+.8f}"
            f" = {res.r3_fix:+.8f}"
        )
        d1 = res.r1_origin - res.r1_offset
        d2 = res.r2_origin - res.r2_offset
        lines.append(
            f"  R1_fix = (R1_origin - R1_offset) / R3_offset"
            f" = ({res.r1_origin:+.8f} - {res.r1_offset:+.8f}) / {res.r3_offset:+.8f}"
            f" = {d1:+.8f} / {res.r3_offset:+.8f} = {res.r1_fix:+.8f}"
        )
        lines.append(
            f"  R2_fix = (R2_origin - R2_offset) / R3_offset"
            f" = ({res.r2_origin:+.8f} - {res.r2_offset:+.8f}) / {res.r3_offset:+.8f}"
            f" = {d2:+.8f} / {res.r3_offset:+.8f} = {res.r2_fix:+.8f}"
        )
    else:
        lines.append(f"  R3_fix = {res.r3_fix:+.8f}")
        lines.append(f"  R1_fix = {res.r1_fix:+.8f}")
        lines.append(f"  R2_fix = {res.r2_fix:+.8f}")

    sin_d = math.hypot(res.r1_fix, res.r2_fix) if math.isfinite(res.r1_fix) else float("nan")
    lines.extend([
        "",
        "=== 8. 式 9.1  rho ===",
        f"  rho = 0.5 * atan2(R2_fix, R1_fix)"
        f" = 0.5 * atan2({res.r2_fix:+.8f}, {res.r1_fix:+.8f})",
    ])
    if res.ok and math.isfinite(res.rho_deg):
        lines.append(f"  rho = {res.rho_deg:+.6f} deg  ({res.rho_deg / 180.0 * math.pi:.8f} rad)")
    else:
        lines.append(f"  rho = ---  ({res.message})")

    lines.extend([
        "",
        "=== 9. 式 9.2  delta ===",
        f"  sin_delta = sqrt(R1_fix^2 + R2_fix^2) = {sin_d:.8f}",
        f"  delta = atan2(sin_delta, R3_fix)"
        f" = atan2({sin_d:.8f}, {res.r3_fix:+.8f})",
    ])
    if res.ok and math.isfinite(res.delta_nm):
        lines.append(
            f"  delta = {res.delta_rad:.8f} rad = {res.delta_nm:.6f} nm"
        )
        if abs(res.r3_fix) <= 1.0:
            acos_d = math.degrees(
                math.acos(max(-1.0, min(1.0, res.r3_fix)))
            )
            lines.append(f"  (对照 acos(R3_fix)) delta = {acos_d:.4f} deg")
    else:
        lines.append(f"  delta = ---  ({res.message})")

    return "\n".join(lines)
