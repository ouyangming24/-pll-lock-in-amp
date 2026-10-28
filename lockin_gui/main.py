"""
main.py
───────
锁相放大器 GUI 启动入口。

用法:
    python main.py            # ★ 默认: 串口模式 (板载 CH340, PyCharm 点 Run 也是这个)
    python main.py --serial   # 兼容旧脚本, 等同于默认
    python main.py --udp      # 以太网 UDP 模式 (仅旧版以太网 bit 可用)
    python main.py --demo     # 离线模拟模式 (无板子调试 GUI)
    python main.py --help

模式说明:
    串口模式 (默认):  PC <─ USB 线 (板载 CH340) ─> FPGA   (命令 + 数据 + 示波器)
                      921600 8N1, 端口下拉框自动选中 CH340
    UDP 模式 (--udp): PC <─ 网线 UDP ─> FPGA   (FPGA 192.168.99.10:1234, 仅旧版 bit)
    DEMO 模式 (--demo): 不连接硬件, 用内置数据生成器调试 GUI 视觉
"""

import argparse
import sys

from PyQt5.QtWidgets import QApplication

from main_window import MainWindow


def main():
    parser = argparse.ArgumentParser(
        description="数字锁相放大器 GUI (默认走板载 CH340 串口)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--demo", action="store_true",
        help="离线模拟模式: 不连接真实硬件, 用内置数据生成器调试 GUI",
    )
    mode.add_argument(
        "--udp", action="store_true",
        help="以太网 UDP 模式 (仅旧版以太网 bit 可用)",
    )
    # --serial 保留为向后兼容: 现在已经是默认行为, 加上也不报错
    mode.add_argument(
        "--serial", action="store_true",
        help="兼容旧脚本; 现在已经是默认行为",
    )
    args = parser.parse_args()

    app = QApplication(sys.argv)
    win = MainWindow(demo_mode=args.demo, udp_mode=args.udp)
    win.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
