# =============================================================================
#  eth_pins.xdc
#  千兆以太网 (RTL8211E RGMII) 引脚 + I/O 标准 + 时序约束
#
#  目标硬件: LXB-ZYNQ (XC7Z020-CLG484)
#  PHY: Realtek RTL8211E-VB-CG (RGMII 接 PL 端 BANK)
#
#  注: sys_clk (M19, PL_CLK_50M) 在 pin.xdc 中已经声明并 create_clock,
#      本文件不再重复声明.
# =============================================================================

# ----------------------------------------------------------------------------
# 1) RGMII 引脚分配 (按 LXB-ZYNQ 文档)
# ----------------------------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN H17} [get_ports eth_nrst]

set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B19 SLEW FAST} [get_ports eth_rxc]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A21 SLEW FAST} [get_ports eth_rxctl]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A22 SLEW FAST} [get_ports {eth_rxd[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A18 SLEW FAST} [get_ports {eth_rxd[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A19 SLEW FAST} [get_ports {eth_rxd[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B20 SLEW FAST} [get_ports {eth_rxd[3]}]

set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D21 SLEW FAST DRIVE 12} [get_ports eth_txc]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G22 SLEW FAST DRIVE 12} [get_ports eth_txctl]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E21 SLEW FAST DRIVE 12} [get_ports {eth_txd[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F21 SLEW FAST DRIVE 12} [get_ports {eth_txd[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F22 SLEW FAST DRIVE 12} [get_ports {eth_txd[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G20 SLEW FAST DRIVE 12} [get_ports {eth_txd[3]}]

set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G21} [get_ports eth_mdc]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN H22} [get_ports eth_mdio]

# ----------------------------------------------------------------------------
# 2) PL LED (可选, 不接外设也无所谓)
# ----------------------------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN P20} [get_ports pl_led1]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN P21} [get_ports pl_led2]

# ----------------------------------------------------------------------------
# 3) 时序约束: RGMII 接收时钟
#    RTL8211E 默认开启 RX 时钟 2 ns 内部延迟, 即 RXC 与 RXD 中心对齐.
#    告诉 Vivado RXC 是 125 MHz (千兆模式).
# ----------------------------------------------------------------------------
create_clock -period 8.000 -name eth_rxc [get_ports eth_rxc]

# RX 数据相对 RXC 的相位 (默认 ±0.5 ns 容限)
set_input_delay -clock [get_clocks eth_rxc] -max  0.5 [get_ports {eth_rxctl eth_rxd[*]}]
set_input_delay -clock [get_clocks eth_rxc] -min -0.5 [get_ports {eth_rxctl eth_rxd[*]}]
set_input_delay -clock [get_clocks eth_rxc] -clock_fall -max -add_delay  0.5 [get_ports {eth_rxctl eth_rxd[*]}]
set_input_delay -clock [get_clocks eth_rxc] -clock_fall -min -add_delay -0.5 [get_ports {eth_rxctl eth_rxd[*]}]

# ----------------------------------------------------------------------------
# 4) 时序约束: RGMII 发送时钟
#    我们用 125 MHz_90° (clk125_90) 驱动 eth_txc, 数据用 clk125 (0°),
#    这样数据相对 TXC 自动有 2 ns 偏移.
#    告诉 Vivado 输出延迟容限.
# ----------------------------------------------------------------------------
# 由 ODDR 生成的 eth_txc 的虚拟时钟
create_generated_clock -name eth_txc_clk -source [get_pins u_eth_top/u_clk_wiz_eth/inst/clk_out2] \
    -multiply_by 1 [get_ports eth_txc]

set_output_delay -clock [get_clocks eth_txc_clk] -max  1.0 [get_ports {eth_txctl eth_txd[*]}]
set_output_delay -clock [get_clocks eth_txc_clk] -min -1.0 [get_ports {eth_txctl eth_txd[*]}]
set_output_delay -clock [get_clocks eth_txc_clk] -clock_fall -max -add_delay  1.0 [get_ports {eth_txctl eth_txd[*]}]
set_output_delay -clock [get_clocks eth_txc_clk] -clock_fall -min -add_delay -1.0 [get_ports {eth_txctl eth_txd[*]}]

# ----------------------------------------------------------------------------
# 5) 时钟域隔离: 65 MHz 锁相 与 125 MHz 以太网 之间不需要进行时序检查
#    (跨域已通过 XPM_FIFO_ASYNC 处理)
# ----------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks {sys_clk}] \
    -group [get_clocks -include_generated_clocks -of_objects [get_pins u_eth_top/u_clk_wiz_eth/inst/clk_out1]] \
    -group [get_clocks -include_generated_clocks -of_objects [get_pins u_eth_top/u_clk_wiz_eth/inst/clk_out2]] \
    -group [get_clocks eth_rxc]

# ----------------------------------------------------------------------------
# 6) MDIO 是 inout, 不参与高速时序 (我们设为静态高阻)
# ----------------------------------------------------------------------------
set_false_path -to   [get_ports eth_mdio]
set_false_path -from [get_ports eth_mdio]
set_false_path -to   [get_ports eth_mdc]
