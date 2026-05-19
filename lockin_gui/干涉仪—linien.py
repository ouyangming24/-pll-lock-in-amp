"""
锁定状态下用 raw + 高 decimation 模式取高分辨率残差信号。
要求：脚本运行时激光必须已经在锁定状态。
"""
import pickle
import time
import numpy as np
import matplotlib.pyplot as plt
from scipy.signal import welch

from linien_client.connection import LinienClient
from linien_client.device import Device

# === 1. 连接 ============================================================
c = LinienClient(Device(
    host="rp-F0BE57.local",
    username="root",
    password="root",
))
c.connect(autostart_server=True, use_parameter_cache=True)
assert c.parameters.lock.value, "请先把激光锁定再跑这个脚本！"

# === 2. 切到 raw 模式 ===================================================
DECIMATION_INDEX = 12                      # CIC 抽取指数；先用 12，不够就调高
fs_eff = 125e6 / (2 ** DECIMATION_INDEX)   # 有效采样率, ~30.5 kS/s
n_points = 16384                           # raw 模式下满帧
record_time = n_points / fs_eff            # 录满需要的时间, ~0.54 s

# 保存原参数，跑完恢复
saved = {
    "raw_enabled":   c.parameters.acquisition_raw_enabled.value,
    "raw_decim":     c.parameters.acquisition_raw_decimation.value,
    "raw_filt_en":   c.parameters.acquisition_raw_filter_enabled.value,
    "raw_filt_freq": c.parameters.acquisition_raw_filter_frequency.value,
}

c.connection.root.exposed_pause_acquisition()
c.parameters.acquisition_raw_enabled.value         = True
c.parameters.acquisition_raw_decimation.value      = DECIMATION_INDEX
c.parameters.acquisition_raw_filter_enabled.value  = True
c.parameters.acquisition_raw_filter_frequency.value = int(fs_eff / 2)
c.connection.root.exposed_write_registers()
c.connection.root.exposed_continue_acquisition()

# 等录满 + 一点裕量
print(f"采样率 {fs_eff:.1f} Hz, 录满约需 {record_time*1000:.0f} ms ...")
time.sleep(record_time + 1.0)

# === 3. 取数据 ==========================================================
raw = pickle.loads(c.parameters.acquisition_raw_data.value)
err = np.asarray(raw[0], dtype=np.float64)   # 误差信号通道, LSB14

# === 4. 恢复普通模式 ====================================================
c.connection.root.exposed_pause_acquisition()
c.parameters.acquisition_raw_enabled.value         = saved["raw_enabled"]
c.parameters.acquisition_raw_decimation.value      = saved["raw_decim"]
c.parameters.acquisition_raw_filter_enabled.value  = saved["raw_filt_en"]
c.parameters.acquisition_raw_filter_frequency.value = saved["raw_filt_freq"]
c.connection.root.exposed_write_registers()
c.connection.root.exposed_continue_acquisition()

# === 5. 报告 ============================================================
LSB_TO_V = 1.0 / 8192            # 14 位 ±1 V 量程下 1 LSB = 122 μV
err_centered = err - err.mean()  # 算抖动只关心交流分量

print("============================================================")
print(f"decimation index = {DECIMATION_INDEX}, fs_eff = {fs_eff:.1f} Hz")
print(f"采样点数:        {len(err)}")
print(f"取值唯一数:      {len(np.unique(err))}")
print(f"min/max/ptp:     {err.min():.0f} / {err.max():.0f} / {err.ptp():.0f} LSB14")
print(f"mean:            {err.mean():.3f}  LSB14")
print(f"std (counts):    {err.std():.4f} LSB14")
print(f"std (V):         {err.std()*LSB_TO_V*1e6:.2f} μV  ← 锁定残差 RMS")
print(f"std (Hz, 假设斜率 K=...): 用 std / K 自己换算")
print("============================================================")

# === 6. 画图 ============================================================
fig, axes = plt.subplots(2, 1, figsize=(10, 6))
t = np.arange(len(err)) / fs_eff

axes[0].plot(t, err_centered * LSB_TO_V * 1e6, lw=0.6)
axes[0].set_xlabel("Time [s]")
axes[0].set_ylabel("Error (mean removed) [μV]")
axes[0].set_title(f"高分辨率误差信号 (decimation 2^{DECIMATION_INDEX} = {2**DECIMATION_INDEX})")
axes[0].grid(alpha=0.3)

f, Pxx = welch(err_centered * LSB_TO_V, fs=fs_eff,
               window="hann", nperseg=min(2048, len(err)//4),
               scaling="density")
axes[1].loglog(f[1:], np.sqrt(Pxx[1:]) * 1e6)
axes[1].set_xlabel("Frequency [Hz]")
axes[1].set_ylabel("PSD [μV/√Hz]")
axes[1].set_title("误差信号 PSD")
axes[1].grid(which="both", alpha=0.3)

plt.tight_layout()
plt.show()