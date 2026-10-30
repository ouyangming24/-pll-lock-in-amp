"""
模拟 FPGA 串口端 (SDKOUT 精简流), 无板子时测试 lockin_sdk_osc1.

需要一对虚拟串口 (如 com0com: COM1 <-> COM2):
    python fake_fpga.py COM2          # SDK 连 COM1

行为:
  - 命令 "<NAME>:<十进制>\\r\\n" / "stop" / "SDKOUT" → "Command Success!\\r\\n"
  - SDKOUT 后约 2000 帧/s 发 28 字节帧 (osc1 X/Y + V3/V4/V5)
  - 流模式下收到命令时先发半帧 (模拟打断), 再发应答
  - 每秒插入几个垃圾字节
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
FRAME_SYNC = b"\xA5\x5A\xC3\x01"

OK = b"Command Success!\r\n"
ERR = b"Command Error!\r\n"

VALUE_CMDS = [
    "FRQ21", "TAU21", "ORD21", "REFMODE",
    "DMOD", "DWAV", "DAMP", "DOFS", "BAUD",
    "OSC1", "OSRC1", "OHN1",
]
ALLOWED_BAUD = {9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600}


def hz_word(hz):
    return int(round(hz * (1 << PHASE_BITS) / F_CLK)) & ((1 << PHASE_BITS) - 1)


def crc(b):
    return binascii.crc_hqx(b, 0xFFFF)


class FakeFpga:
    def __init__(self, port):
        self.ser = serial.Serial(port, 115200, timeout=0.01)
        self.lock = threading.Lock()
        self.state = {k: 0 for k in VALUE_CMDS}
        self.state["BAUD"] = 115200
        self.state["FRQ21"] = hz_word(10e3)
        self.state["OHN1"] = 1
        self.state["TAU21"] = 12
        self.state["ORD21"] = 2
        self.streaming = False
        self.frame_seq = 0
        self.sample_cnt = 0
        self.cmd_log = []
        self.running = True
        self.t0 = time.time()

    def frame_bytes(self):
        self.frame_seq += 1
        self.sample_cnt = (self.sample_cnt + 500) & 0xFFFFFFFF
        t = time.time() - self.t0
        # 假数据: osc1 缓慢变化; V3/V4/V5 小幅三角波
        x = int(1000 + 50 * (t % 10))
        y = int(-500 + 20 * ((t * 1.7) % 10))
        phase = int((t * 1e5) % 2000) - 1000
        v3 = phase
        v4 = -phase // 2
        v5 = phase // 3
        body = FRAME_SYNC + struct.pack(">iihhhII", x, y, v3, v4, v5,
                                         self.sample_cnt, self.frame_seq)
        return body + crc(body).to_bytes(2, "big")

    def handle(self, line):
        self.cmd_log.append(line)
        if line == "stop":
            self.streaming = False
            return OK
        if line == "SDKOUT":
            self.streaming = True
            return OK
        if ":" not in line:
            return ERR
        name, val = line.split(":", 1)
        if name not in self.state or not val.isdigit():
            return ERR
        iv = int(val)
        if name == "BAUD":
            if iv not in ALLOWED_BAUD:
                return ERR
            self.state[name] = iv
            # 应答仍用旧波特率发出; 真实 FPGA 随后切换, 假设备保持打开速率不变
            return OK
        self.state[name] = iv
        return OK

    def tx_loop(self):
        while self.running:
            with self.lock:
                streaming = self.streaming
            if streaming:
                pkt = self.frame_bytes()
                with self.lock:
                    self.ser.write(pkt)
                time.sleep(0.0005)  # ~2 kHz
            else:
                time.sleep(0.005)

    def junk_loop(self):
        while self.running:
            time.sleep(1.0)
            with self.lock:
                if self.streaming:
                    self.ser.write(bytes([random.randint(0, 255) for _ in range(3)]))

    def run(self):
        threading.Thread(target=self.tx_loop, daemon=True).start()
        threading.Thread(target=self.junk_loop, daemon=True).start()
        buf = b""
        try:
            while True:
                chunk = self.ser.read(256)
                if chunk:
                    buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.rstrip(b"\r").decode("ascii", errors="ignore")
                    if not line:
                        continue
                    with self.lock:
                        streaming = self.streaming
                        if streaming:
                            # 半帧打断
                            half = self.frame_bytes()[:14]
                            self.ser.write(half)
                        resp = self.handle(line)
                        self.ser.write(resp)
        except KeyboardInterrupt:
            pass
        finally:
            self.running = False
            with open("fake_fpga_cmds.txt", "w", encoding="utf-8") as f:
                f.write("\n".join(self.cmd_log))
            self.ser.close()
            print("logged", len(self.cmd_log), "cmds -> fake_fpga_cmds.txt")


def main():
    if len(sys.argv) < 2:
        print("usage: python fake_fpga.py COMx")
        sys.exit(1)
    print("fake FPGA (SDKOUT) on", sys.argv[1])
    FakeFpga(sys.argv[1]).run()


if __name__ == "__main__":
    main()
