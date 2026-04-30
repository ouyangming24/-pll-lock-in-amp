"""
main.py
───────
锁相放大器 GUI 启动入口。

用法:
    python main.py            # 真实硬件模式 (FT245BL VCP)
    python main.py --demo     # 离线模拟模式 (无板子调试 GUI)
    python main.py --help
"""

import argparse
import sys

from PyQt5.QtWidgets import QApplication

from main_window import MainWindow


def main():
    parser = argparse.ArgumentParser(description="数字锁相放大器 GUI")
    parser.add_argument(
        "--demo", action="store_true",
        help="离线模拟模式: 不连接真实硬件, 用内置数据生成器调试 GUI",
    )
    args = parser.parse_args()

    app = QApplication(sys.argv)
    win = MainWindow(demo_mode=args.demo)
    win.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
