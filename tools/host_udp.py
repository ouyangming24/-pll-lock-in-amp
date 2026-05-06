"""
host_udp.py
-----------
通过 *以太网 UDP* 与 FPGA 锁相放大器通信 (PL 端 RGMII PHY 直接发 UDP)。
配置命令仍走 FT245 串口 (因为 FPGA 当前只有上行迁移到了 UDP).

依赖:
    pip install pyserial numpy

用法:
    1. 把 FT245 配成 VCP 模式 (用于命令), 板上网线接 PC
    2. PC 网卡静态 IP 设为 192.168.1.100, 子网 255.255.255.0
    3. python host_udp.py
    4. 可选: python host_udp.py --save out.csv

调试技巧:
    - 用 Wireshark 过滤 udp.port == 7777 验证 FPGA 是否在发包
    - 抓不到 ARP, 试试 ping 192.168.1.10 (虽然 FPGA 不响应 ICMP, 但能触发 ARP)
"""

import argparse
import csv
import socket
import struct
import sys
import time
from collections import deque

import serial

# ============================================================================
# 配置
# ============================================================================
# 命令通道 (FT245 VCP)
SERIAL_PORT     = "COM5"          # ★ 改成你的实际 COM 号
SERIAL_BAUDRATE = 3_000_000       # FT245 VCP 下波特率被忽略
SERIAL_TIMEOUT  = 0.5

# 数据通道 (UDP)
UDP_LISTEN_IP   = "0.0.0.0"       # 监听所有网卡
UDP_LISTEN_PORT = 7777            # 与 eth_lockin_top 的 DEST_PORT 一致
UDP_RECV_BUFSZ  = 65536           # socket 内核缓冲

# 协议格式 (与 lock_in_amp.v 的 x_y_fir_packed 完全一致)
SYNC_HEADER = b"\xA5\x5A\xA5\x5A"
FRAME_LEN   = 80                  # 4 sync + 11i + 3i + 2Q + 1i
FRAME_FMT   = ">11i3iQQi"         # 大端

# DDS 参数 (用于频率字 ↔ Hz 换算)
F_CLK      = 65_000_000
PHASE_BITS = 48

# ============================================================================
# 工具函数
# ============================================================================
def freq_word_to_hz(word: int) -> float:
    return word * F_CLK / (1 << PHASE_BITS)


def parse_frame(buf: bytes) -> dict:
    """解析 80 字节 UDP 载荷 → 数据字典. 失败抛 ValueError."""
    if len(buf) != FRAME_LEN:
        raise ValueError(f"frame len {len(buf)} != 80")
    if buf[:4] != SYNC_HEADER:
        raise ValueError(f"bad sync {buf[:4].hex()}")
    vals = struct.unpack(FRAME_FMT, buf[4:])
    return {
        "ch1_x":             vals[0],
        "ch1_y":             vals[1],
        "ch2_x":             vals[2],
        "ch2_y":             vals[3],
        "ch3_x_21":          vals[4],
        "ch3_y_21":          vals[5],
        "ch3_x_12":          vals[6],
        "ch3_y_12":          vals[7],
        "ch3_x_11":          vals[8],
        "ch3_y_11":          vals[9],
        "ch3_dc":            vals[10],
        "adc_ch1":           vals[11],
        "adc_ch2":           vals[12],
        "adc_ch3":           vals[13],
        "pll_freq_ch1_word": vals[14],
        "pll_freq_ch2_word": vals[15],
        "lock_flags":        vals[16],
        "pll_freq_ch1_hz":   freq_word_to_hz(vals[14]),
        "pll_freq_ch2_hz":   freq_word_to_hz(vals[15]),
        "locked_ch1":        bool(vals[16] & 0x1),
        "locked_ch2":        bool(vals[16] & 0x2),
    }


# ============================================================================
# 命令通道 (FT245 串口)
# ============================================================================
class CmdChannel:
    def __init__(self, port: str, baud: int = SERIAL_BAUDRATE, optional: bool = False):
        self.optional = optional
        try:
            self.ser = serial.Serial(port, baud, timeout=SERIAL_TIMEOUT)
            print(f"[+] 命令串口已连接 {port}")
        except Exception as e:
            self.ser = None
            if optional:
                print(f"[!] 命令串口未连接 ({e}); 仅启动数据接收, 不下发命令")
            else:
                raise

    def send(self, cmd: str) -> str:
        if self.ser is None:
            return ""
        self.ser.write((cmd + "\r\n").encode("ascii"))
        time.sleep(0.05)
        resp = self.ser.read(64).decode("ascii", errors="replace").strip()
        print(f"  >> {cmd:20s} ← {resp}")
        return resp

    def close(self):
        if self.ser:
            try: self.ser.close()
            except Exception: pass


# ============================================================================
# 主流程
# ============================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port",  default=SERIAL_PORT,  help="命令串口 (默认 %(default)s)")
    ap.add_argument("--ip",    default=UDP_LISTEN_IP, help="UDP 监听 IP (默认 %(default)s)")
    ap.add_argument("--udp",   type=int, default=UDP_LISTEN_PORT, help="UDP 端口 (默认 %(default)s)")
    ap.add_argument("--save",  help="保存接收数据到 CSV 文件")
    ap.add_argument("--no-cmd", action="store_true", help="不连接串口, 只接收 UDP")
    ap.add_argument("--no-config", action="store_true", help="连接串口但不下发参数 (假设已配置)")
    args = ap.parse_args()

    # ----- 打开命令串口 (可选) -----
    cmd = CmdChannel(args.port, optional=args.no_cmd) if not args.no_cmd else CmdChannel("", optional=True)

    # ----- 下发参数 -----
    if cmd.ser and not args.no_config:
        print("\n[+] 配置锁相参数")
        cmd.send("KP:500")
        cmd.send("KI:50")
        cmd.send("TAUX:20")
        cmd.send("TAUY:8")
        cmd.send("PHAS:0")
        cmd.send("FRQ2:433038425708")    # tx1 频率字 (~50 kHz)
        cmd.send("FRQ3:346430740")        # tx2 频率字 (~40 kHz, 修正过了的值, 见下注释)
        # 注: 上面 FRQ3 = round(40000 * 2^48 / 65e6) = 346,430,740
        #     原 host_vcp.py 里写的 433038425 是 ~50kHz 的, 应是笔误.

        # 注意: XYOUT 命令现在依然只控制 FT245 上行通道. 我们不需要它来启动 UDP,
        # 因为 udp_lockin_tx 是被 dc_valid 自动触发的, FPGA 上电就开始发包.
        # 这里发 XYOUT 只是为了让 FT245 也同步发, 方便对比验证.
        # 如果不想 FT245 也发数据 (会刷 USB 总线), 可以注释掉.
        # cmd.send("XYOUT")

    # ----- 打开 UDP socket -----
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, UDP_RECV_BUFSZ)
    sock.bind((args.ip, args.udp))
    sock.settimeout(1.0)              # 1 秒超时, 用于打印 "等待数据" 心跳
    print(f"\n[+] UDP socket 监听 {args.ip}:{args.udp}")

    # ----- (可选) 打开 CSV 文件 -----
    csv_writer = None
    csv_file = None
    if args.save:
        csv_file = open(args.save, "w", newline="", encoding="utf-8")
        csv_writer = csv.writer(csv_file)
        csv_writer.writerow([
            "time", "ch1_x","ch1_y","ch2_x","ch2_y",
            "ch3_x_21","ch3_y_21","ch3_x_12","ch3_y_12",
            "ch3_x_11","ch3_y_11","ch3_dc",
            "adc_ch1","adc_ch2","adc_ch3",
            "pll_freq_ch1_hz","pll_freq_ch2_hz",
            "locked_ch1","locked_ch2",
        ])
        print(f"[+] 数据将保存到 {args.save}")

    # ----- 主循环 -----
    print("\n[+] 接收数据 (Ctrl+C 停止)")
    print("=" * 110)

    n_total   = 0
    n_bad     = 0
    n_window  = 0       # 当前 1 秒窗口内的帧数
    t_window  = time.time()
    fps_hist  = deque(maxlen=10)

    try:
        while True:
            try:
                payload, addr = sock.recvfrom(2048)
            except socket.timeout:
                print(f"  [...等待 UDP 数据 (已收 {n_total} 帧, 最近 1s={n_window} fps)...]")
                continue

            n_total += 1
            n_window += 1

            try:
                d = parse_frame(payload)
            except ValueError as e:
                n_bad += 1
                if n_bad < 5:
                    print(f"  [!] 解析失败 ({e}) 来自 {addr[0]}:{addr[1]}")
                continue

            # 每秒打印一行汇总
            t = time.time()
            if t - t_window >= 1.0:
                fps = n_window / (t - t_window)
                fps_hist.append(fps)
                avg_fps = sum(fps_hist) / len(fps_hist)
                lock_str = f"L1={'O' if d['locked_ch1'] else 'X'} L2={'O' if d['locked_ch2'] else 'X'}"
                print(
                    f"[{time.strftime('%H:%M:%S')}] "
                    f"fps={fps:6.1f} (avg={avg_fps:6.1f})  "
                    f"ch1=({d['ch1_x']:>+10d},{d['ch1_y']:>+10d})  "
                    f"F1={d['pll_freq_ch1_hz']:9.2f}Hz  "
                    f"F2={d['pll_freq_ch2_hz']:9.2f}Hz  "
                    f"{lock_str}  "
                    f"bad={n_bad}"
                )
                n_window  = 0
                t_window  = t

            # 写 CSV
            if csv_writer:
                csv_writer.writerow([
                    f"{t:.6f}",
                    d["ch1_x"], d["ch1_y"], d["ch2_x"], d["ch2_y"],
                    d["ch3_x_21"], d["ch3_y_21"],
                    d["ch3_x_12"], d["ch3_y_12"],
                    d["ch3_x_11"], d["ch3_y_11"],
                    d["ch3_dc"],
                    d["adc_ch1"], d["adc_ch2"], d["adc_ch3"],
                    f"{d['pll_freq_ch1_hz']:.4f}",
                    f"{d['pll_freq_ch2_hz']:.4f}",
                    int(d["locked_ch1"]),
                    int(d["locked_ch2"]),
                ])

    except KeyboardInterrupt:
        print("\n[+] 停止")
    finally:
        if cmd.ser:
            cmd.send("stop")
        cmd.close()
        sock.close()
        if csv_file:
            csv_file.close()
            print(f"[+] CSV 已保存 ({n_total} 帧)")
        print(f"[+] 统计: 共收 {n_total} 帧, 解析失败 {n_bad} 帧")


if __name__ == "__main__":
    main()
