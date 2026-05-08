"""
main.py
───────
锁相放大器 GUI 启动入口。

用法:
    python main.py            # 串口模式: 上下行都走 FT245 (传统)
    python main.py --udp      # 以太网模式: 命令走 FT245, 数据走以太网 UDP
    python main.py --demo     # 离线模拟模式 (无板子调试 GUI)
    python main.py --help

模式说明:
    串口模式  (默认):   PC <─ FT245 USB ─> FPGA   (上下行都走 USB)
    UDP 模式  (--udp):  PC <─ FT245 USB ─> FPGA   (命令)
                        PC <─ 网线 UDP   ─> FPGA   (数据, 千兆速率)
    DEMO 模式 (--demo): 不连接硬件, 用内置数据生成器调试 GUI 视觉
"""

import argparse
import sys

from PyQt5.QtWidgets import QApplication

from main_window import MainWindow


def main():
    parser = argparse.ArgumentParser(description="数字锁相放大器 GUI")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--demo", action="store_true",
        help="离线模拟模式: 不连接真实硬件, 用内置数据生成器调试 GUI",
    )
    mode.add_argument(
        "--udp", action="store_true",
        help="以太网模式: 命令走 FT245 串口, 数据走 UDP (千兆 RGMII PHY)",
    )
    args = parser.parse_args()

    app = QApplication(sys.argv)
    win = MainWindow(demo_mode=args.demo, udp_mode=args.udp)
    win.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
