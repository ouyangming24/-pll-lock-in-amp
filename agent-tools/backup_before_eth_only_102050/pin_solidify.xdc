# =============================================================================
# pin_solidify.xdc
# 适配 design_1_wrapper（端口名带 _0）
# 器件: xc7z020clg484
#
# 用法:
#   - 仅启用本文件
#   - 禁用: pin.xdc / eth_pins.xdc / eht_pinx_solidify.xdc
# =============================================================================

# -----------------------------------------------------------------------------
# AD7606C-16 (ACM7606C 模块 P3, VDRIVE = 3.3 V)
#   复用原两片 AD9248 的管脚: 数据线/BUSY/FRSTDATA 用原 ADC1 管脚,
#   控制线用原 ADC2 管脚. 必须与实际飞线/转接板一致!
#   模块跳线: PSB_SEL 接 GND (并口), REF_SEL 接高 (内部基准), 拔掉 H5.
# -----------------------------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E16} [get_ports {ad_db_0[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F16} [get_ports {ad_db_0[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D18} [get_ports {ad_db_0[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C19} [get_ports {ad_db_0[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D15} [get_ports {ad_db_0[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E15} [get_ports {ad_db_0[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D17} [get_ports {ad_db_0[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D16} [get_ports {ad_db_0[7]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B15} [get_ports {ad_db_0[8]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C15} [get_ports {ad_db_0[9]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D20} [get_ports {ad_db_0[10]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C20} [get_ports {ad_db_0[11]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A17} [get_ports {ad_db_0[12]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A16} [get_ports {ad_db_0[13]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B16} [get_ports {ad_db_0[14]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B17} [get_ports {ad_db_0[15]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G15} [get_ports ad_busy_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G16} [get_ports ad_frstdata_0]

set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V14}  [get_ports ad_convst_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V15}  [get_ports ad_wr_n_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y14}  [get_ports ad_rd_n_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA14} [get_ports ad_cs_n_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W16}  [get_ports ad_reset_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y16}  [get_ports {ad_os_0[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA17} [get_ports {ad_os_0[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB17} [get_ports {ad_os_0[2]}]

# 异步并口: 时序由驱动按拍数保证 (RD 低 4 拍 61 ns >= tD_RD_DB 30 ns), 不做 IO 时序分析
set_false_path -from [get_ports {ad_db_0[*] ad_busy_0 ad_frstdata_0}]
set_false_path -to   [get_ports {ad_db_0[*] ad_convst_0 ad_wr_n_0 ad_rd_n_0 ad_cs_n_0 ad_reset_0 ad_os_0[*]}]

# -----------------------------------------------------------------------------
# FT245 FIFO
# -----------------------------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN H20} [get_ports {ft_d_0[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F18} [get_ports {ft_d_0[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G17} [get_ports {ft_d_0[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C18} [get_ports {ft_d_0[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F19} [get_ports {ft_d_0[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E19} [get_ports {ft_d_0[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C22} [get_ports {ft_d_0[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B21} [get_ports {ft_d_0[7]}]

set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B22} [get_ports ft_rd_n_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D22} [get_ports ft_wr_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E20} [get_ports ft_rxf_n_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G19} [get_ports ft_txe_n_0]

# -----------------------------------------------------------------------------
# DAC（14 bit，管脚来自 pin copy.xdc，不要用旧的 10 bit da_data 约束）
# -----------------------------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB16} [get_ports dac_pd_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA16} [get_ports dac_clk_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA19} [get_ports {da_data_0[13]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y19}  [get_ports {da_data_0[12]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB19} [get_ports {da_data_0[11]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB20} [get_ports {da_data_0[10]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB21} [get_ports {da_data_0[9]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA21} [get_ports {da_data_0[8]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB22} [get_ports {da_data_0[7]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA22} [get_ports {da_data_0[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y21}  [get_ports {da_data_0[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y20}  [get_ports {da_data_0[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W22}  [get_ports {da_data_0[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V22}  [get_ports {da_data_0[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN U22}  [get_ports {da_data_0[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN T22}  [get_ports {da_data_0[0]}]

# -----------------------------------------------------------------------------
# 板载晶振 50 MHz + 复位（lock_in_amp 已改回 External，不再用 FCLK）
# -----------------------------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN M19} [get_ports sys_clk_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN J20} [get_ports sys_rst_n_0]
create_clock -period 20.000 -name sys_clk [get_ports sys_clk_0]

# -----------------------------------------------------------------------------
# 时钟域隔离
# 不要对 sys_clk 使用 -include_generated_clocks（会把 65M 生成钟并进同组）。
# -----------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks clk_out1_clk_wiz_0] \
    -group [get_clocks -quiet clkfbout_clk_wiz_0] \
    -group [get_clocks -quiet clk_fpga_0]
