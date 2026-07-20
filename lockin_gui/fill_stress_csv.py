"""为旧版 lockin CSV (无 stress_* 列) 补算应力值.

用法:
  python fill_stress_csv.py "0706_174105 - 副本.csv" "0706_171645 - 副本.csv"

规则:
  - 谐波 X/Y: mV peak → V_rms (÷1000, ÷√2)
  - 直流: mV → V (÷1000)
  - Offset: 首行数据
  - K: 默认 1.0 (文件头无 STRESS_K 时)
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import pandas as pd

from stress_calc import ChannelVoltages, StressCalib, StressInputs, compute_stress

_SQRT2 = math.sqrt(2.0)

STRESS_COLS = [
    "stress_ok",
    "stress_rho_deg",
    "stress_delta_nm",
    "stress_r1_fix",
    "stress_r2_fix",
    "stress_r3_fix",
]


def _mv_peak_to_v_rms(mv: float) -> float:
    return (mv / 1000.0) / _SQRT2


def _mv_to_v(mv: float) -> float:
    return mv / 1000.0


def _row_voltages(row: pd.Series) -> tuple[ChannelVoltages, ChannelVoltages, ChannelVoltages, float]:
    x1 = _mv_peak_to_v_rms(row["ch3_21_X_mV"])
    y1 = _mv_peak_to_v_rms(row["ch3_21_Y_mV"])
    x2 = _mv_peak_to_v_rms(row["ch3_12_X_mV"])
    y2 = _mv_peak_to_v_rms(row["ch3_12_Y_mV"])
    x3 = _mv_peak_to_v_rms(row["ch3_11_X_mV"])
    y3 = _mv_peak_to_v_rms(row["ch3_11_Y_mV"])
    vdc = _mv_to_v(row["ch3_dc_mV"])
    return (
        ChannelVoltages(x1, y1),
        ChannelVoltages(x2, y2),
        ChannelVoltages(x3, y3),
        vdc,
    )


def _read_meta(path: Path) -> list[str]:
    lines: list[str] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                lines.append(line.rstrip("\n"))
            else:
                break
    return lines


def _stress_meta_lines(
    o1: ChannelVoltages,
    o2: ChannelVoltages,
    o3: ChannelVoltages,
    vdc_off: float,
) -> list[str]:
    return [
        "# --- 应力计算参数 (后处理: Offset=首行, K=1) ---",
        "# stress_voltage_unit = V_rms (谐波), V (直流)",
        "# STRESS_K_OSC1      = 1.000000",
        "# STRESS_K_OSC2      = 1.000000",
        "# STRESS_K_OSC3      = 1.000000",
        "# STRESS_K_DC        = 1.000000",
        f"# STRESS_OFF_OSC1_X  = {o1.x:.6f}",
        f"# STRESS_OFF_OSC1_Y  = {o1.y:.6f}",
        f"# STRESS_OFF_OSC2_X  = {o2.x:.6f}",
        f"# STRESS_OFF_OSC2_Y  = {o2.y:.6f}",
        f"# STRESS_OFF_OSC3_X  = {o3.x:.6f}",
        f"# STRESS_OFF_OSC3_Y  = {o3.y:.6f}",
        f"# STRESS_OFF_DC      = {vdc_off:.6f}",
        "#",
    ]


def fill_stress_csv(path: Path) -> None:
    meta = _read_meta(path)
    df = pd.read_csv(path, comment="#")

    if all(c in df.columns for c in STRESS_COLS):
        print(f"[skip] {path.name}: 已有 stress_* 列")
        return

    o1, o2, o3, vdc_off = _row_voltages(df.iloc[0])
    calib = StressCalib()

    rows_out = []
    ok_n = 0
    for _, row in df.iterrows():
        osc1, osc2, osc3, vdc = _row_voltages(row)
        inp = StressInputs(
            osc1=osc1,
            osc2=osc2,
            osc3=osc3,
            v_dc=vdc,
            offset1=o1,
            offset2=o2,
            offset3=o3,
            v_dc_offset=vdc_off,
            calib=calib,
        )
        res = compute_stress(inp)
        if res.ok:
            ok_n += 1
        rows_out.append({
            "stress_ok": int(res.ok),
            "stress_rho_deg": res.rho_deg if math.isfinite(res.rho_deg) else float("nan"),
            "stress_delta_nm": res.delta_nm if math.isfinite(res.delta_nm) else float("nan"),
            "stress_r1_fix": res.r1_fix if math.isfinite(res.r1_fix) else float("nan"),
            "stress_r2_fix": res.r2_fix if math.isfinite(res.r2_fix) else float("nan"),
            "stress_r3_fix": res.r3_fix if math.isfinite(res.r3_fix) else float("nan"),
        })

    stress_df = pd.DataFrame(rows_out)
    for c in STRESS_COLS:
        df[c] = stress_df[c]

    # 去掉旧 meta 里可能重复的 stress 块
    meta_clean = [ln for ln in meta if not ln.startswith("# --- 应力") and not ln.startswith("# stress_")
                  and not ln.startswith("# STRESS_")]
    if meta_clean and not meta_clean[-1].startswith("#"):
        pass
    new_meta = meta_clean + _stress_meta_lines(o1, o2, o3, vdc_off)

    with path.open("w", newline="", encoding="utf-8") as f:
        f.write("\n".join(new_meta) + "\n")
        df.to_csv(f, index=False, lineterminator="\n")

    print(f"[ok] {path.name}: {len(df)} 行, stress_ok={ok_n}, "
          f"首行 ρ={rows_out[0]['stress_rho_deg']:.4f}° δ={rows_out[0]['stress_delta_nm']:.4f} nm")


def main() -> None:
    if len(sys.argv) < 2:
        paths = [
            Path("0706_174105 - 副本.csv"),
            Path("0706_171645 - 副本.csv"),
        ]
    else:
        paths = [Path(p) for p in sys.argv[1:]]

    base = Path(__file__).resolve().parent
    for p in paths:
        fp = p if p.is_absolute() else base / p
        if not fp.exists():
            print(f"[!] 找不到: {fp}")
            continue
        fill_stress_csv(fp)


if __name__ == "__main__":
    main()
