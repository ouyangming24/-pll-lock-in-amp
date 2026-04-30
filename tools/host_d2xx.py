"""
host_d2xx.py
------------
通过 FT245BL（D2XX 模式, pyftdi 直驱）与 FPGA 锁相放大器通信。

依赖:
    pip install pyftdi numpy

前置:
    1. 在 FT_PROG 里把 FT245BL 改回 D2XX (或者用 Zadig 换驱动)
    2. 列出可用设备:  python -m pyftdi.ftdi_urls
"""

import struct
import time
from pyftdi.ftdi import Ftdi
import numpy as np

# =====================================================================
# 配置
# =====================================================================
URL = "ftdi://ftdi:232:/1"        # 改成 ftdi_urls 列出的实际 URL
SYNC_HEADER = b"\xA5\x5A\xA5\x5A"
FRAME_LEN = 48

# =====================================================================
# 1) 打开设备
# =====================================================================
ftdi = Ftdi()
ftdi.open_from_url(URL)
ftdi.set_baudrate(3_000_000)        # FT245 模式下波特率被忽略
ftdi.set_latency_timer(2)           # 默认 16ms 太慢, 改 2ms
ftdi.purge_buffers()
print(f"[+] 已连接 {URL}")


def send_cmd(cmd: str):
    ftdi.write_data((cmd + "\r\n").encode("ascii"))
    time.sleep(0.05)
    resp = ftdi.read_data(20).decode("ascii", errors="replace").strip()
    print(f"  >> {cmd:20s} ← {resp}")


# =====================================================================
# 2) 配置 + 启动数据流
# =====================================================================
send_cmd("KP:500")
send_cmd("KI:50")
send_cmd("TAUX:20")
send_cmd("TAUY:8")
send_cmd("PHAS:0")
send_cmd("FRQ2:433038425708")
send_cmd("FRQ3:433038425")
send_cmd("XYOUT")


# =====================================================================
# 3) 大批量接收 (D2XX 一次拉好多帧, 速度爆表)
# =====================================================================
def parse_frames(buf: bytes):
    """从字节流里搜出所有完整帧, 返回 (frames_list, leftover_bytes)"""
    out = []
    while True:
        idx = buf.find(SYNC_HEADER)
        if idx < 0 or len(buf) - idx < FRAME_LEN:
            break
        out.append(buf[idx:idx + FRAME_LEN])
        buf = buf[idx + FRAME_LEN:]
    return out, buf


print("\n[+] 高速接收 (Ctrl+C 停止)")
buf = b""
n = 0
t0 = time.time()
try:
    while True:
        chunk = ftdi.read_data(4096)        # 一次拉 4KB
        if chunk:
            buf += chunk
            frames, buf = parse_frames(buf)
            n += len(frames)
            if frames:
                f = struct.unpack(">11i", frames[-1][4:])
                if n % 100 == 0:
                    rate = n / (time.time() - t0)
                    print(f"#{n:6d}  rate={rate:7.1f} fps  "
                          f"ch1=({f[0]:+12d},{f[1]:+12d})  "
                          f"ch3_dc={f[10]:+12d}")
except KeyboardInterrupt:
    pass
finally:
    send_cmd("stop")
    ftdi.close()
    print(f"\n共收到 {n} 帧")
