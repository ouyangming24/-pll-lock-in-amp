# 项目手册：双通道数字锁相放大器（串口版 v1）

> 适用版本：2026-10-23 之后的**串口版**（命令 + 数据全部走板载 CH340，921600 8N1）。
> 以太网版 / FT245 版的资料见文末"历史文档"。

## 一句话说明

Zynq-7020 PL 端实现的数字锁相放大器：AD7606C 采 8 路信号（1 MSPS），
通道 1/2 用 PLL 锁定外部信号频率 F1/F2，通道 3 用 7 个振荡器（参考频率可手动设定，
或由 n·F1+m·F2 自动生成）做相敏解调，DAC904 输出任一振荡器的参考信号，
V5/V6 两路可做示波器抓波形。上位机有 Python GUI 和 C++ SDK 两种，通过 CH340 串口控制。

## 文档列表

| 文档 | 什么时候看 |
|---|---|
| [01_系统架构.md](01_系统架构.md) | 想搞清楚"信号从哪来、经过什么、到哪去" |
| [02_通信协议_串口版.md](02_通信协议_串口版.md) | 写上位机 / 改命令 / 解析数据（**协议以这份为准**） |
| [03_构建与复现.md](03_构建与复现.md) | 重新出 bit、固化、打包 GUI、编译 SDK、无板子测试 |
| [04_决策记录.md](04_决策记录.md) | 想知道"为什么这样设计" |
| [05_已知问题与排障.md](05_已知问题与排障.md) | 东西不正常时 |
| [06_速查表.md](06_速查表.md) | 日常查引脚、命令、常数（一页纸） |
| [07_掌握自测题.md](07_掌握自测题.md) | 检验自己是否吃透，附答案 |

## 推荐阅读顺序

- **第一次接手**：01 → 06 → 02 → 03
- **出问题**：05 → 06 → 02
- **隔了很久回来**：06（5 分钟）→ 01 的框图 → 05 的已知问题 → 跑一遍 03 第 6 节的无板子测试

## 复习节奏

| 时间 | 做什么 |
|---|---|
| 项目结束当天 | 通读本手册，补充自己记得但手册里没有的内容 |
| 1 周后 | 不看资料做 07 的 A、B 两部分，答不上的回去看 |
| 1 个月后 | 做 07 的 C 部分（动手加一条命令） |
| 之后每季度 | 看 06 速查表 + 05 已知问题，约 30 分钟 |

## 代码与产物位置

| 内容 | 路径 |
|---|---|
| FPGA 顶层 / 模块 | `project_1.srcs/sources_1/new/`（顶层 `lock_in_amp.v`） |
| 引脚约束（唯一启用） | `project_1.srcs/constrs_1/new/pin_solidify.xdc` |
| BD 更新脚本 | `tools/uart_only_bd_update.tcl` |
| 已验证的串口版 bit | `agent-tools/uart_only_verified_bit/` |
| 修改前备份 | `agent-tools/backup_before_uart_only_10231638/` |
| Python GUI 源码 | `lockin_gui/`（入口 `main.py`） |
| GUI 绿色包 | `lockin_gui/dist/LockinGUI/` |
| C++ SDK | `lockin_sdk_cpp/`（见其 `README.md`） |
| 问题日志（按时间） | `docs/issue_log.md` |

## 历史文档（已过时，仅供参考）

以下文档描述的是 FT245 或以太网时期的系统，**命令名、帧格式、通信方式与现在不一致**，
查协议请以 [02_通信协议_串口版.md](02_通信协议_串口版.md) 为准：

- `docs/UART_Protocol.md`、`docs/Interface_Spec_for_SW.md`：FT245 时期的协议说明
- `docs/ethernet_migration_plan.md`、`docs/ethernet_migration_retrospective.md`：以太网迁移
- `docs/notes/README.md`：早期学习笔记索引（其中链接的 01~05 笔记文件不在仓库里）

仍然有效的专题文档：

- `docs/帧协议v2_时间戳与CRC.md`：数据帧 v2（178 字节 + CRC）的设计说明
- `docs/iir_lpf_ema_butterworth_derivation.md`、`docs/一阶低通滤波器完整推导.md`：IIR 推导
- `docs/pll_controller_flowchart.md`：PLL 控制流程
- `docs/issue_log.md`：历次问题记录
