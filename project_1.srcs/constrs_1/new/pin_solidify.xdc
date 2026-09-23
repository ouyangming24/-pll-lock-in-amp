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
# ADC 通道 1
# -----------------------------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B16} [get_ports adc_otr_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B17} [get_ports adc_pdn_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A16} [get_ports {adc_data_0[13]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A17} [get_ports {adc_data_0[12]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C20} [get_ports {adc_data_0[11]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D20} [get_ports {adc_data_0[10]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C15} [get_ports {adc_data_0[9]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B15} [get_ports {adc_data_0[8]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D16} [get_ports {adc_data_0[7]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D17} [get_ports {adc_data_0[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E15} [get_ports {adc_data_0[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D15} [get_ports {adc_data_0[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C19} [get_ports {adc_data_0[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D18} [get_ports {adc_data_0[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F16} [get_ports {adc_data_0[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E16} [get_ports {adc_data_0[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G15} [get_ports adc_oeb_b_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G16} [get_ports adc_clk_0]

# -----------------------------------------------------------------------------
# ADC 通道 2
# -----------------------------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V15}  [get_ports adc_oeb_b_2_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V14}  [get_ports adc_clk_2_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y14}  [get_ports {adc_data_2_0[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA14} [get_ports {adc_data_2_0[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W16}  [get_ports {adc_data_2_0[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y16}  [get_ports {adc_data_2_0[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA17} [get_ports {adc_data_2_0[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB17} [get_ports {adc_data_2_0[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W18}  [get_ports {adc_data_2_0[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W17}  [get_ports {adc_data_2_0[7]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V13}  [get_ports {adc_data_2_0[8]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W13}  [get_ports {adc_data_2_0[9]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y13}  [get_ports {adc_data_2_0[10]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA13} [get_ports {adc_data_2_0[11]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB14} [get_ports {adc_data_2_0[12]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB15} [get_ports {adc_data_2_0[13]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y18}  [get_ports adc_pdn_2_0]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA18} [get_ports adc_otr_2_0]

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
