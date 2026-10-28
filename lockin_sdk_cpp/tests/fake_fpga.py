"""
模拟 FPGA 串口端 (usb_commend.v 的协议), 用于没有板子时测试 SDK.

需要一对虚拟串口 (如 ELTIMA / com0com: COM1 <-> COM2):
    python fake_fpga.py COM2          # SDK 连 COM1

行为:
  - 命令 "<NAME>:<十进制>\\r\\n" / "stop" / "XYOUT" → "Command Success!r\\n";
    未知命令或格式错 → "Command Error!\\r\\n"
  - XYOUT 后约 450 帧/s 发 178 字节数据帧; 流模式下收到命令时先发半帧
    (模拟 FPGA 被命令打断), 再发应答
  - SCAP 后发 4114 字节示波器包 (V5 = i-512, V6 = 1000-2i, 便于校验)
  - 第一个示波器包故意写坏 CRC, 用来验证 SDK 的超时重发
  - 每秒插入几个垃圾字节
  - 退出时把收到的命令写到 fake_fpga_cmds.txt
"""
import binascii
import random
import struct
import sys
import threading
import time

import serial

F_CLK = 65_000_000
PHASE_BITS = 48
FRAME_SYNC = b"\xA5\x5A\xA5\x5A"
SCOPE_SYNC = b"\xA5\x5A\x5A\xA5"
FRAME_FMT = ">19i3iQQi7QII"

OK = b"Command Success!r\n"
ERR = b"Command Error!\r\n"

VALUE_CMDS = (
    ["FRQ21", "FRQ12", "FRQ11", "FRQ4", "FRQ5", "FRQ6", "FRQ7",
     "TAU21", "TAU12", "TAU11", "TAU4", "TAU5", "TAU6", "TAU7",
     "ORD21", "ORD12", "ORD11", "ORD4", "ORD5", "ORD6", "ORD7",
     "REFMODE", "DMOD", "DWAV", "DAMP", "DOFS", "SCAP", "STLV", "SDEC"]
    + [f"OSC{k}" for k in range(1, 8)]
    + [f"OSRC{k}" for k in range(1, 8)]
    + [f"OHN{k}" for k in range(1, 8)]
)
FRQ_OF_OSC = ["FRQ21", "FRQ12", "FRQ11", "FRQ4", "FRQ5", "FRQ6", "FRQ7"]


def hz_word(hz):
    return int(round(hz * (1 << PHASE_BITS) / F_CLK)) & ((1 << PHASE_BITS) - 1)


def crc(b):
    return binascii.crc_hqx(b, 0xFFFF)


class FakeFpga:
    def __init__(self, port):
        self.ser = serial.Serial(port, 921600, timeout=0.01)
        self.lock = threading.Lock()
        self.state = {k: 0 for k in VALUE_CMDS}
        for i, hz in enumerate([160e3, 170e3, 110e3, 150e3, 180e3, 220e3, 200e3]):
            self.state[FRQ_OF_OSC[i]] = hz_word(hz)
        for k in range(1, 8):
            self.state[f"OHN{k}"] = 1
        self.streaming = False
        self.frame_seq = 0
        self.sample_cnt = 0
        self.scope_seq = 0
        self.scope_count = 0
        self.cmd_log = []
        self.running = True

    # ------------------------------------------------------------------
    def frame_bytes(self):
        self.frame_seq += 1
        self.sample_cnt = (self.sample_cnt + 2222) & 0xFFFFFFFF
        vals = [1, -2, 3, -4]
        for k in range(7):
            vals += [1000 * (k + 1), -500 * (k + 1)]
        vals += [-12345]                          # ch3_dc
        vals += [11, 22, 33]                      # adc
        vals += [hz_word(1000.0), hz_word(2000.0)]
        vals += [3]                               # lock_flags
        for k in range(7):
            vals += [(self.state[FRQ_OF_OSC[k]] * self.state[f"OHN{k + 1}"]) & ((1 << 48) - 1)]
        vals += [self.sample_cnt, self.frame_seq]
        body = FRAME_SYNC + struct.pack(FRAME_FMT, *vals)
        return body + crc(body).to_bytes(2, "big")

    def scope_bytes(self, mode):
        n, pre = 1024, 128
        decim = self.state["SDEC"] & 0xFFFF
        trig = mode & 0x7
        forced = 1 if trig != 0 else 0
        self.scope_seq += 1
        hdr = SCOPE_SYNC + struct.pack(">HHHBBI", n, pre, decim, (trig << 1) | forced, 0, self.scope_seq)
        smp = b"".join(struct.pack(">hh", i - 512, 1000 - 2 * i) for i in range(n))
        body = hdr + smp
        c = crc(body)
        self.scope_count += 1
        if self.scope_count == 1:
            c ^= 0x1234                           # 第一包故意坏 CRC
        return body + c.to_bytes(2, "big")

    # ------------------------------------------------------------------
    def handle(self, line):
        self.cmd_log.append(line)
        if line == "stop":
            self.streaming = False
            return OK, None
        if line == "XYOUT":
            self.streaming = True
            return OK, None
        if ":" not in line:
            return ERR, None
        name, val = line.split(":", 1)
        if name not in self.state or not val.isdigit():
            return ERR, None
        self.state[name] = int(val)
        if name == "SCAP":
            return OK, int(val)
        return OK, None

    def rx_loop(self):
        buf = b""
        while self.running:
            data = self.ser.read(256)
            if not data:
                continue
            buf += data
            while True:
                idx = min([i for i in (buf.find(b"\r"), buf.find(b"\n")) if i >= 0], default=-1)
                if idx < 0:
                    break
                line, buf = buf[:idx].decode(errors="replace").strip(), buf[idx + 1:]
                if not line:
                    continue
                resp, scap = self.handle(line)
                with self.lock:
                    if self.streaming or line == "stop":
                        self.ser.write(self.frame_bytes()[:50])   # 被命令打断的半帧
                    self.ser.write(resp)
                if scap is not None:
                    threading.Thread(target=self.send_scope, args=(scap,), daemon=True).start()

    def send_scope(self, mode):
        time.sleep(0.02)
        pkt = self.scope_bytes(mode)
        with self.lock:
            self.ser.write(pkt)

    def tx_loop(self):
        last_junk = time.time()
        while self.running:
            if self.streaming:
                with self.lock:
                    self.ser.write(b"".join(self.frame_bytes() for _ in range(9)))
                time.sleep(0.02)
            else:
                time.sleep(0.01)
            if time.time() - last_junk > 1.0:
                last_junk = time.time()
                with self.lock:
                    self.ser.write(bytes(random.randrange(256) for _ in range(5)))

    def run(self, seconds):
        threads = [threading.Thread(target=self.rx_loop, daemon=True),
                   threading.Thread(target=self.tx_loop, daemon=True)]
        for t in threads:
            t.start()
        print(f"fake_fpga: ready on {self.ser.port}", flush=True)
        try:
            t_end = time.time() + seconds
            while time.time() < t_end:
                time.sleep(0.1)
        except KeyboardInterrupt:
            pass
        self.running = False
        time.sleep(0.1)
        self.ser.close()
        with open("fake_fpga_cmds.txt", "w") as f:
            f.write("\n".join(self.cmd_log) + "\n")
        print(f"fake_fpga: {len(self.cmd_log)} commands, {self.frame_seq} frames, "
              f"{self.scope_count} scope packets")


if __name__ == "__main__":
    port = sys.argv[1] if len(sys.argv) > 1 else "COM2"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 1e9
    FakeFpga(port).run(secs)
