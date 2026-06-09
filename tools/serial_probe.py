"""快速探测 FT245 串口是否在发 XYOUT 数据帧."""
import struct
import sys
import time

import serial

SYNC = b"\xA5\x5A\xA5\x5A"
PORT = sys.argv[1] if len(sys.argv) > 1 else "COM14"
BAUD = 3_000_000


def main():
    ser = serial.Serial(PORT, BAUD, timeout=0.2)
    print(f"[+] 打开 {PORT}")
    ser.reset_input_buffer()
    ser.write(b"XYOUT\r\n")
    print("[+] 已发 XYOUT, 监听 5 秒...")

    buf = b""
    t0 = time.time()
    frames_80 = frames_48 = 0
    while time.time() - t0 < 5.0:
        buf += ser.read(512)
        while True:
            idx = buf.find(SYNC)
            if idx < 0:
                break
            buf = buf[idx:]
            if len(buf) >= 80:
                frames_80 += 1
                vals = struct.unpack(">11i3iQQi", buf[4:80])
                print(f"  80B帧 #{frames_80}: ch1_x={vals[0]:+d} ch1_y={vals[1]:+d}")
                buf = buf[80:]
            elif len(buf) >= 48:
                frames_48 += 1
                vals = struct.unpack(">11i", buf[4:48])
                print(f"  48B旧帧 #{frames_48}: ch1_x={vals[0]:+d} ch1_y={vals[1]:+d}")
                buf = buf[48:]
            else:
                break

    print(f"[=] 5s 统计: 总字节 {len(buf)} (残留缓冲), 80B帧={frames_80}, 48B帧={frames_48}")
    if frames_80 == 0 and frames_48 == 0:
        print("[!] 无数据帧 — 常见原因:")
        print("    1) COM 口不对 / FPGA 未连接")
        print("    2) bitstream 过旧 (PLL 未启用 → dc_valid 不跳)")
        print("    3) 需重新烧录含 CDC 修复的最新 bitstream")
    ser.write(b"stop\r\n")
    ser.close()


if __name__ == "__main__":
    main()
