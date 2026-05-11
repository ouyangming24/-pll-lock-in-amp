"""
main.py  (★ 旧版 串口数据流版本 GUI ★)
─────────────────────────────────────
这是 lockin_gui/ 的历史快照, 数据流走串口 (FT245 USB) 而不是以太网 UDP.
保留作为兜底 / 历史参考. 新功能请去 ../lockin_gui/ 主线.

用法:
    python main.py            # ★ 默认: 串口模式 (本目录的本意)
    python main.py --demo     # 离线模拟模式 (无板子调试 GUI)
    python main.py --udp      # 仍可临时走 UDP (代码尚未删, 但本目录不再维护)
    python main.py --help

模式说明:
    串口模式 (默认):    PC <─ FT245 USB ─> FPGA   (上下行都走 USB)
    UDP 模式 (--udp):   PC <─ FT245 USB ─> FPGA   (命令)
                        PC <─ 网线 UDP   ─> FPGA   (数据, 千兆速率)
    DEMO 模式 (--demo): 不连接硬件, 用内置数据生成器调试 GUI 视觉
"""

import argparse
import sys

from PyQt5.QtWidgets import QApplication

from main_window import MainWindow


def main():
    parser = argparse.ArgumentParser(
        description="数字锁相放大器 GUI · 旧版串口版本",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--demo", action="store_true",
        help="离线模拟模式: 不连接真实硬件, 用内置数据生成器调试 GUI",
    )
    mode.add_argument(
        "--udp", action="store_true",
        help="临时切换到 UDP 模式 (本目录的默认是串口)",
    )
    args = parser.parse_args()

    app = QApplication(sys.argv)
    win = MainWindow(demo_mode=args.demo, udp_mode=args.udp)
    win.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
