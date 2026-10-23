"""
main.py
───────
锁相放大器 GUI 启动入口。

用法:
    python main.py            # ★ 默认: 以太网 UDP 模式 (PyCharm 点 Run 也是这个)
    python main.py --serial   # 串口模式: 上下行都走 FT245 (兜底, 已不推荐)
    python main.py --demo     # 离线模拟模式 (无板子调试 GUI)
    python main.py --udp      # 兼容旧脚本, 等同于默认
    python main.py --help

模式说明:
    UDP 模式  (默认):    PC <─ FT245 USB ─> FPGA   (命令)
                         PC <─ 网线 UDP   ─> FPGA   (数据, 千兆速率)
    串口模式 (--serial): PC <─ FT245 USB ─> FPGA   (上下行都走 USB, 仅兜底)
    DEMO 模式 (--demo):  不连接硬件, 用内置数据生成器调试 GUI 视觉
"""

import argparse
import sys

from PyQt5.QtWidgets import QApplication

from main_window import MainWindow


def main():
    parser = argparse.ArgumentParser(
        description="数字锁相放大器 GUI (默认走以太网 UDP)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--demo", action="store_true",
        help="离线模拟模式: 不连接真实硬件, 用内置数据生成器调试 GUI",
    )
    mode.add_argument(
        "--serial", action="store_true",
        help="串口模式 (兜底): 命令+数据都走 FT245 USB",
    )
    # --udp 保留为向后兼容: 现在已经是默认行为, 加上也不报错
    mode.add_argument(
        "--udp", action="store_true",
        help="兼容旧脚本; 现在已经是默认行为",
    )
    args = parser.parse_args()

    # 默认 UDP, 只有显式 --serial 才回退串口
    udp_mode = not args.serial and not args.demo

    app = QApplication(sys.argv)
    win = MainWindow(demo_mode=args.demo, udp_mode=udp_mode)
    win.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
