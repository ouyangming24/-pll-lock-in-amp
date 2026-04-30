"""
host_vcp.py
-----------
通过 FT245BL（VCP 模式，看作 COM 口）与 FPGA 锁相放大器通信。

依赖:
    pip install pyserial numpy

用法:
    1. 先在 FT_PROG 里把 FT245BL 配成 VCP 模式
    2. 设备管理器看 COM 端口号, 改下面 PORT 常量
    3. python host_vcp.py
"""

import struct
import time
import serial
import numpy as np

# =====================================================================
# 配置
# =====================================================================
PORT     = "COM5"        # 改成你的实际端口
BAUDRATE = 3_000_000     # FT245 在 VCP 模式下波特率被忽略, 随便填
TIMEOUT  = 0.5

SYNC_HEADER = b"\xA5\x5A\xA5\x5A"   # 必须和 lock_in_amp.v 里的同步头一致
FRAME_LEN   = 48                    # 4字节同步头 + 11个 int32

# =====================================================================
# 1) 打开端口
# =====================================================================
ser = serial.Serial(PORT, BAUDRATE, timeout=TIMEOUT)
print(f"[+] 已连接 {PORT}")

# =====================================================================
# 2) 发送命令的工具函数
#    协议: 命令以 ASCII 字符串发送, 用 \r\n 结尾
# =====================================================================
def send_cmd(cmd: str) -> str:
    """发送命令, 等 FPGA 回 'Command Success!' 或 'Command Error!'"""
    ser.write((cmd + "\r\n").encode("ascii"))
    time.sleep(0.05)
    resp = ser.read(20).decode("ascii", errors="replace").strip()
    print(f"  >> {cmd:20s} ← {resp}")
    return resp


# =====================================================================
# 3) 配置锁相参数 (按需改值)
# =====================================================================
print("\n[+] 配置参数")
send_cmd("KP:500")              # PLL 比例系数
send_cmd("KI:50")               # PLL 积分系数
send_cmd("TAUX:20")             # X 路 IIR 平滑 (5bit, 范围 0-31)
send_cmd("TAUY:8")              # Y 路 IIR 平滑
send_cmd("PHAS:0")              # tx1 相位偏移
send_cmd("FRQ2:433038425708")   # tx1 频率字
send_cmd("FRQ3:433038425")      # tx2 频率字

# =====================================================================
# 4) 启动数据回传 → FPGA 进入 SEND_XYDATA 模式
# =====================================================================
print("\n[+] 启动 XYOUT 数据流")
send_cmd("XYOUT")

# =====================================================================
# 5) 接收并解析 48 字节帧
# =====================================================================
def parse_frame(buf: bytes) -> dict:
    """大端解析 48 字节帧 → 字典"""
    assert len(buf) == FRAME_LEN
    assert buf[:4] == SYNC_HEADER, "同步头不对!"
    vals = struct.unpack(">11i", buf[4:])
    return {
        "ch1_x":     vals[0],
        "ch1_y":     vals[1],
        "ch2_x":     vals[2],
        "ch2_y":     vals[3],
        "ch3_x_21":  vals[4],   # 通道3 @ 2F1+F2 X
        "ch3_y_21":  vals[5],
        "ch3_x_12":  vals[6],   # 通道3 @ F1+2F2 X
        "ch3_y_12":  vals[7],
        "ch3_x_11":  vals[8],   # 通道3 @ F1+F2 X
        "ch3_y_11":  vals[9],
        "ch3_dc":    vals[10],
    }


print("\n[+] 接收数据 (Ctrl+C 停止)")
buf = b""
try:
    while True:
        buf += ser.read(64)
        idx = buf.find(SYNC_HEADER)
        if idx >= 0 and len(buf) - idx >= FRAME_LEN:
            frame = buf[idx:idx + FRAME_LEN]
            buf = buf[idx + FRAME_LEN:]
            d = parse_frame(frame)
            print(f"ch1=({d['ch1_x']:>+11d},{d['ch1_y']:>+11d})  "
                  f"ch3@F1+F2=({d['ch3_x_11']:>+11d},{d['ch3_y_11']:>+11d})  "
                  f"ch3_dc={d['ch3_dc']:>+11d}")
except KeyboardInterrupt:
    print("\n[+] 停止数据流")
    send_cmd("stop")
    ser.close()
