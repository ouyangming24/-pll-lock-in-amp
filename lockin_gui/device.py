"""
device.py
─────────
设备抽象层:
  - LockinDevice    : 真实 FPGA 通信 (FT245BL VCP 模式, pyserial), 上下行都走串口
  - UdpLockinDevice : ★ 新版 ★ 命令走 FT245 串口, 数据走以太网 UDP
                     (FPGA PL 端千兆 RGMII 直接发 UDP, 见 docs/ethernet_migration_plan.md)
  - MockDevice      : 离线模拟器, 产生伪锁相数据 (用于无硬件时调试 GUI)

三个类都是 QObject, 发出相同的 Qt 信号供 main_window 订阅:
  - frame_received(dict)
  - log_message(str)
  - connection_changed(bool)
  - cmd_response(str)
"""

import math
import socket
import struct
import threading
import time
from collections import deque
from random import gauss

import serial
import serial.tools.list_ports
from PyQt5.QtCore import QObject, pyqtSignal, QTimer

# ============================================================================
# 协议常量 (与 docs/Interface_Spec_for_SW.md 保持一致)
# ============================================================================
SYNC_HEADER = b"\xA5\x5A\xA5\x5A"
FRAME_LEN = 80                    # 4 sync + 11i + 3i + 2Q + 1i
F_CLK = 65_000_000                # DDS 时钟 (Hz)
PHASE_BITS = 48                   # DDS 相位累加器位宽

# 数据字段名 (顺序必须与 lock_in_amp.v 的打包顺序一致)
# 11 个锁相输出 + 3 个原始 ADC + 2 个锁定频率字 + 1 个锁定标志
FIELD_NAMES = [
    "ch1_x", "ch1_y",
    "ch2_x", "ch2_y",
    "ch3_x_21", "ch3_y_21",
    "ch3_x_12", "ch3_y_12",
    "ch3_x_11", "ch3_y_11",
    "ch3_dc",
    "adc_ch1", "adc_ch2", "adc_ch3",
    "pll_freq_ch1_word", "pll_freq_ch2_word",
    "lock_flags",
]

# struct 格式: 11 int32 + 3 int32 + 2 uint64 + 1 int32 (大端)
FRAME_FMT = ">11i3iQQi"


# ============================================================================
# 工具函数
# ============================================================================
def hz_to_freq_word(hz: float) -> int:
    """物理频率 (Hz) → DDS 频率字 (48 bit 整数)"""
    return int(round(hz * (1 << PHASE_BITS) / F_CLK)) & ((1 << PHASE_BITS) - 1)


def freq_word_to_hz(word: int) -> float:
    """DDS 频率字 → 物理频率 (Hz)"""
    return word * F_CLK / (1 << PHASE_BITS)


def list_serial_ports() -> list:
    """枚举系统所有可用串口"""
    return [p.device for p in serial.tools.list_ports.comports()]


def parse_frame(buf: bytes) -> dict:
    """大端解析 80 字节帧 → 数据字典 (额外提供解析后的 Hz/lock 值)"""
    if len(buf) != FRAME_LEN:
        raise ValueError("帧长度错误")
    if buf[:4] != SYNC_HEADER:
        raise ValueError("同步头不匹配")
    vals = struct.unpack(FRAME_FMT, buf[4:])
    data = dict(zip(FIELD_NAMES, vals))
    # 派生量, 方便 GUI 使用
    data["pll_freq_ch1_hz"] = freq_word_to_hz(data["pll_freq_ch1_word"])
    data["pll_freq_ch2_hz"] = freq_word_to_hz(data["pll_freq_ch2_word"])
    data["locked_ch1"] = bool(data["lock_flags"] & 0x1)
    data["locked_ch2"] = bool(data["lock_flags"] & 0x2)
    data["timestamp"] = time.time()
    return data


# ============================================================================
# 真实设备 (FT245BL VCP 模式)
# ============================================================================
class LockinDevice(QObject):
    frame_received = pyqtSignal(dict)
    log_message = pyqtSignal(str)
    connection_changed = pyqtSignal(bool)
    cmd_response = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        self.ser: serial.Serial | None = None
        self._streaming = False
        self._thread: threading.Thread | None = None
        self._cmd_lock = threading.Lock()

    # --- 连接管理 ----------------------------------------------------------
    def connect(self, port: str, baud: int = 3_000_000) -> bool:
        try:
            self.ser = serial.Serial(port, baud, timeout=0.05)
            self.connection_changed.emit(True)
            self.log_message.emit(f"[+] 已连接 {port} @ {baud}")
            return True
        except Exception as e:
            self.log_message.emit(f"[!] 连接失败: {e}")
            return False

    def disconnect(self):
        self.stop_streaming()
        if self.ser:
            try:
                self.ser.close()
            except Exception:
                pass
            self.ser = None
        self.connection_changed.emit(False)
        self.log_message.emit("[+] 已断开")

    @property
    def is_connected(self) -> bool:
        return self.ser is not None and self.ser.is_open

    # --- 命令收发 ----------------------------------------------------------
    def send_command(self, cmd: str) -> str:
        """发送一条 ASCII 命令, 返回 FPGA 应答字符串

        ⚠ 关键:
        - 流模式下 *只能* write, 不能在主线程 read,
          否则会与 _rx_loop 后台线程并发 read 同一串口,
          在 Windows 上会触发 pyserial overlapped I/O 崩溃 (闪退).
        - 非流模式下 (start_streaming 之前 / stop 之后) 才能 read 响应.
        """
        if not self.is_connected:
            self.log_message.emit(f"[!] 未连接, 无法发送: {cmd}")
            return ""
        # 写串口本身是线程安全的 (pyserial 允许 1 写 + 1 读),
        # 用锁只是为了序列化多个 send_command 调用 (例如"一键下发").
        with self._cmd_lock:
            try:
                self.ser.write((cmd + "\r\n").encode("ascii"))
            except Exception as e:
                self.log_message.emit(f"[!] 发送异常: {e}")
                return ""

        if self._streaming:
            # 流模式: 不读响应 (响应字节会被 _rx_loop 当作非同步头数据丢弃, 这是 OK 的)
            self.log_message.emit(f"  >> {cmd}")
            return ""

        # 非流模式: 安全读取响应
        try:
            time.sleep(0.05)
            resp = self.ser.read(256).decode("ascii", errors="replace").strip()
            self.log_message.emit(f"  >> {cmd:18s} ← {resp}")
            self.cmd_response.emit(resp)
            return resp
        except Exception as e:
            self.log_message.emit(f"[!] 读响应异常: {e}")
            return ""

    # --- 数据流 ------------------------------------------------------------
    def start_streaming(self):
        if self._streaming:
            return
        self.send_command("XYOUT")
        self._streaming = True
        self._thread = threading.Thread(target=self._rx_loop, daemon=True)
        self._thread.start()
        self.log_message.emit("[+] 数据流已启动")

    def stop_streaming(self):
        if not self._streaming:
            return
        # 1) 先置标志, 让 rx_loop 在下一次循环退出
        self._streaming = False
        # 2) ⚠ 必须先 join rx 线程, 再发 "stop" 命令 -- 否则 send_command
        #    与 rx_loop 同时 read 同一串口, Windows 上会触发 overlapped I/O 崩溃.
        if self._thread:
            self._thread.join(timeout=1.0)
            self._thread = None
        # 3) 现在 rx 线程已退出, 主线程独占串口, 安全地发 stop 并读取响应
        if self.is_connected:
            self.send_command("stop")
        self.log_message.emit("[+] 数据流已停止")

    @property
    def is_streaming(self) -> bool:
        return self._streaming

    def _rx_loop(self):
        """后台线程: 持续从串口读取并解析 80 字节数据帧.

        本线程是唯一允许从串口 read 的线程. send_command 在流模式下
        只 write 不 read, 以避免与本线程并发 read 导致 Windows
        overlapped I/O 崩溃.
        """
        buf = b""
        try:
            while self._streaming and self.ser:
                try:
                    chunk = self.ser.read(512)
                except Exception as e:
                    if self._streaming:
                        self.log_message.emit(f"[!] 接收异常: {e}")
                    break
                if not chunk:
                    continue
                buf += chunk
                # 搜帧, 一次可能搜到多帧
                while True:
                    idx = buf.find(SYNC_HEADER)
                    if idx < 0 or len(buf) - idx < FRAME_LEN:
                        break
                    frame = buf[idx:idx + FRAME_LEN]
                    buf = buf[idx + FRAME_LEN:]
                    try:
                        data = parse_frame(frame)
                        self.frame_received.emit(data)
                    except ValueError:
                        pass  # 偶发同步头碰撞, 忽略
                # 防止 buf 无限增长
                if len(buf) > 4096:
                    buf = buf[-2048:]
        finally:
            # 即使被异常打断, 也确保流标志被清掉
            self._streaming = False


# ============================================================================
# 以太网 UDP 设备 (FPGA PL 端 千兆 RGMII 直接发 UDP)
#   - 数据通道: UDP socket, 监听 7777 端口
#   - 命令通道: 仍走 FT245 串口 (FPGA 端 usb_commend 模块没有 UDP 输入)
#   - 一旦 FPGA 端实现 UDP 命令解析, 就可以彻底甩掉 USB
# ============================================================================
UDP_LISTEN_IP   = "0.0.0.0"     # 监听所有网卡
UDP_LISTEN_PORT = 7777          # 与 eth_lockin_top.v 的 DEST_PORT 一致
UDP_RECV_BUFSZ  = 1 << 20       # 1 MiB socket 内核缓冲
UDP_SOCK_TIMEOUT = 0.5          # recvfrom 超时 (s), 让 rx 线程能定期检查退出标志


class UdpLockinDevice(QObject):
    """命令走 FT245 串口, 数据走以太网 UDP (FPGA PL 端千兆 RGMII)"""
    frame_received = pyqtSignal(dict)
    log_message = pyqtSignal(str)
    connection_changed = pyqtSignal(bool)
    cmd_response = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        self.ser: serial.Serial | None = None
        self.sock: socket.socket | None = None
        self._streaming = False
        self._thread: threading.Thread | None = None
        self._cmd_lock = threading.Lock()
        self._stat_total = 0       # 已收帧数
        self._stat_bad   = 0       # 解析失败帧数

    # --- 连接管理 ----------------------------------------------------------
    def connect(self, port: str, baud: int = 3_000_000) -> bool:
        """打开命令串口 + 创建 UDP socket. 任意一步失败都回滚."""
        # 1) 命令串口
        try:
            self.ser = serial.Serial(port, baud, timeout=0.05)
        except Exception as e:
            self.log_message.emit(f"[!] 命令串口 {port} 打开失败: {e}")
            return False

        # 2) UDP socket
        try:
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, UDP_RECV_BUFSZ)
            # SO_REUSEADDR 让程序异常退出后, 端口能立刻被重新 bind
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.sock.bind((UDP_LISTEN_IP, UDP_LISTEN_PORT))
            self.sock.settimeout(UDP_SOCK_TIMEOUT)
        except Exception as e:
            self.log_message.emit(f"[!] UDP 监听 {UDP_LISTEN_PORT} 失败: {e}")
            # 回滚串口
            try: self.ser.close()
            except Exception: pass
            self.ser = None
            self.sock = None
            return False

        self.connection_changed.emit(True)
        self.log_message.emit(
            f"[+] 命令串口 {port} 已打开; UDP 监听 {UDP_LISTEN_IP}:{UDP_LISTEN_PORT}")
        return True

    def disconnect(self):
        self.stop_streaming()
        if self.ser:
            try: self.ser.close()
            except Exception: pass
            self.ser = None
        if self.sock:
            try: self.sock.close()
            except Exception: pass
            self.sock = None
        self.connection_changed.emit(False)
        self.log_message.emit("[+] 已断开")

    @property
    def is_connected(self) -> bool:
        # UDP 模式下, "连接" 等价于 "命令串口已开 + UDP socket 已绑定"
        return (self.ser is not None and self.ser.is_open
                and self.sock is not None)

    # --- 命令收发 (走 FT245 串口) -----------------------------------------
    def send_command(self, cmd: str) -> str:
        """UDP 模式下命令走串口, 数据走 UDP, 没有 read 冲突,
        所以可以直接 write + 读响应 (不用像 LockinDevice 那样区分流模式).
        """
        if not self.is_connected:
            self.log_message.emit(f"[!] 未连接, 无法发送: {cmd}")
            return ""
        with self._cmd_lock:
            try:
                self.ser.write((cmd + "\r\n").encode("ascii"))
                time.sleep(0.05)
                resp = self.ser.read(256).decode("ascii", errors="replace").strip()
                self.log_message.emit(f"  >> {cmd:18s} ← {resp}")
                self.cmd_response.emit(resp)
                return resp
            except Exception as e:
                self.log_message.emit(f"[!] 命令异常: {e}")
                return ""

    # --- 数据流 (走 UDP socket) -------------------------------------------
    def start_streaming(self):
        """UDP 端不需要发 XYOUT — FPGA 端 udp_lockin_tx 是被
        dc_valid 自动触发的, 上电后就一直在发包. 我们只要打开
        socket 接收就行.
        """
        if self._streaming or not self.sock:
            return
        self._streaming = True
        self._stat_total = 0
        self._stat_bad   = 0
        self._thread = threading.Thread(target=self._rx_loop, daemon=True)
        self._thread.start()
        self.log_message.emit("[+] UDP 数据流已启动")

    def stop_streaming(self):
        if not self._streaming:
            return
        self._streaming = False
        if self._thread:
            self._thread.join(timeout=2.0)
            self._thread = None
        self.log_message.emit(
            f"[+] UDP 数据流已停止 (共收 {self._stat_total} 帧, "
            f"解析失败 {self._stat_bad})")

    @property
    def is_streaming(self) -> bool:
        return self._streaming

    def _rx_loop(self):
        """后台线程: 持续 recvfrom UDP, 每个 datagram 必为 80 字节一帧."""
        try:
            while self._streaming and self.sock:
                try:
                    payload, _addr = self.sock.recvfrom(2048)
                except socket.timeout:
                    continue
                except OSError:
                    # socket 被 close 时这里会抛, 直接退出
                    break
                except Exception as e:
                    if self._streaming:
                        self.log_message.emit(f"[!] UDP 接收异常: {e}")
                    break

                self._stat_total += 1
                try:
                    data = parse_frame(payload)
                except ValueError:
                    self._stat_bad += 1
                    continue
                self.frame_received.emit(data)
        finally:
            self._streaming = False


# ============================================================================
# 模拟设备 (用于无板子开发)
# ============================================================================
class MockDevice(QObject):
    frame_received = pyqtSignal(dict)
    log_message = pyqtSignal(str)
    connection_changed = pyqtSignal(bool)
    cmd_response = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        self._connected = False
        self._streaming = False
        self._t0 = time.time()
        self._frame_id = 0
        # 内部状态(被命令修改)
        self.params = {
            "KP": 500, "KI": 50,
            "TAUX": 20, "TAUY": 8,
            "PHAS": 0,
            "FRQ2": hz_to_freq_word(50000),
            "FRQ3": hz_to_freq_word(40000),
        }
        # 模拟数据生成定时器 (~50 fps; 真实硬件帧率 ≤ 10 fps, 这里足够看动效)
        self._timer = QTimer()
        self._timer.timeout.connect(self._gen_frame)
        self._timer.setInterval(20)

    def connect(self, port: str = "DEMO", baud: int = 0) -> bool:
        self._connected = True
        self.connection_changed.emit(True)
        self.log_message.emit("[+] 离线模拟模式 已启动")
        return True

    def disconnect(self):
        self.stop_streaming()
        self._connected = False
        self.connection_changed.emit(False)
        self.log_message.emit("[+] 模拟器已关闭")

    @property
    def is_connected(self) -> bool:
        return self._connected

    def send_command(self, cmd: str) -> str:
        # 模拟命令解析 (不对参数做严格校验)
        if cmd in ("XYOUT", "stop"):
            ok = "Command Success!"
        else:
            try:
                key, val = cmd.split(":")
                self.params[key] = int(val)
                ok = "Command Success!"
            except Exception:
                ok = "Command Error!"
        self.log_message.emit(f"  >> {cmd:18s} ← {ok}  (mock)")
        self.cmd_response.emit(ok)
        return ok

    def start_streaming(self):
        if self._streaming or not self._connected:
            return
        self._streaming = True
        self._t0 = time.time()
        self._timer.start()
        self.log_message.emit("[+] 模拟数据流已启动")

    def stop_streaming(self):
        if not self._streaming:
            return
        self._streaming = False
        self._timer.stop()
        self.log_message.emit("[+] 模拟数据流已停止")

    @property
    def is_streaming(self) -> bool:
        return self._streaming

    def _gen_frame(self):
        """生成一帧伪数据 (与硬件帧字段一致)"""
        t = time.time() - self._t0
        amp_drift = 1.0 + 0.05 * math.sin(2 * math.pi * 0.05 * t)
        noise = lambda s: int(gauss(0, s))

        ch1_amp = 8e6 * amp_drift
        ch2_amp = 5e6 * amp_drift

        # 模拟 PLL 锁定: 启动 2 秒内未锁定, 之后锁定
        locked_ch1 = t > 2.0
        locked_ch2 = t > 2.5
        f1_hz = 50000.0 + 0.5 * math.sin(t * 0.3) if locked_ch1 else 49000 + 500 * t
        f2_hz = 40000.0 + 0.3 * math.sin(t * 0.4) if locked_ch2 else 39000 + 500 * t

        # 模拟 ADC 原始波形 (PC 帧率下的快照, 看上去是慢正弦)
        adc1_raw = int(8000 * math.sin(2 * math.pi * 5 * t)) + noise(200)
        adc2_raw = int(6000 * math.sin(2 * math.pi * 7 * t + 0.5)) + noise(200)
        adc3_raw = int(7000 * math.sin(2 * math.pi * 11 * t)
                       + 3000 * math.sin(2 * math.pi * 17 * t)) + noise(300)
        # 截到 14 bit 范围 (-8192..+8191)
        clip14 = lambda v: max(-8192, min(8191, v))

        data = {
            "ch1_x":     int(ch1_amp * math.cos(0.3)) + noise(50_000),
            "ch1_y":     int(ch1_amp * math.sin(0.3)) + noise(50_000),
            "ch2_x":     int(ch2_amp * math.cos(0.6)) + noise(40_000),
            "ch2_y":     int(ch2_amp * math.sin(0.6)) + noise(40_000),
            "ch3_x_21":  int(2e6   * math.cos(t * 0.8)) + noise(30_000),
            "ch3_y_21":  int(2e6   * math.sin(t * 0.8)) + noise(30_000),
            "ch3_x_12":  int(1.5e6 * math.cos(t * 1.1)) + noise(25_000),
            "ch3_y_12":  int(1.5e6 * math.sin(t * 1.1)) + noise(25_000),
            "ch3_x_11":  int(3e6   * math.cos(t * 0.5)) + noise(40_000),
            "ch3_y_11":  int(3e6   * math.sin(t * 0.5)) + noise(40_000),
            "ch3_dc":    int(5e5 + 1e5 * math.sin(t * 0.2)) + noise(20_000),
            "adc_ch1":   clip14(adc1_raw),
            "adc_ch2":   clip14(adc2_raw),
            "adc_ch3":   clip14(adc3_raw),
            "pll_freq_ch1_word": hz_to_freq_word(f1_hz),
            "pll_freq_ch2_word": hz_to_freq_word(f2_hz),
            "lock_flags":  (1 if locked_ch1 else 0) | (2 if locked_ch2 else 0),
            "pll_freq_ch1_hz": f1_hz,
            "pll_freq_ch2_hz": f2_hz,
            "locked_ch1": locked_ch1,
            "locked_ch2": locked_ch2,
            "timestamp": time.time(),
        }
        self._frame_id += 1
        self.frame_received.emit(data)
