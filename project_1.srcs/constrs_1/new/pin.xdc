
#时序约束
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

#IO管脚约束
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN M19} [get_ports sys_clk]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN J20} [get_ports sys_rst_n]


# 假设您的时钟叫 sys_clk，放宽 IIR 模块内的建立时间检查到 2 个周期
#set_multicycle_path -setup -from [get_cells -hierarchical -filter {NAME =~ *u_iir_lpf_ema*/y_acc_reg*}] -to [get_cells -hierarchical -filter {NAME =~ *u_iir_lpf_ema*/y_acc_reg*}] 2
#set_multicycle_path -hold -from [get_cells -hierarchical -filter {NAME =~ *u_iir_lpf_ema*/y_acc_reg*}] -to [get_cells -hierarchical -filter {NAME =~ *u_iir_lpf_ema*/y_acc_reg*}] 1

#set_multicycle_path -setup -from [get_cells -hierarchical -filter {NAME =~ *u_iir_lpf_ema*/y_acc_reg*}] -to [get_cells -hierarchical -filter {NAME =~ *u_iir_lpf_ema*/dout_reg*}] 2
#set_multicycle_path -hold -from [get_cells -hierarchical -filter {NAME =~ *u_iir_lpf_ema*/y_acc_reg*}] -to [get_cells -hierarchical -filter {NAME =~ *u_iir_lpf_ema*/dout_reg*}] 1

#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B17} [get_ports adc_otr]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B16} [get_ports adc_pdn]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A17} [get_ports {adc_data[13]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A16} [get_ports {adc_data[12]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D20} [get_ports {adc_data[11]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C20} [get_ports {adc_data[10]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B15} [get_ports {adc_data[9]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C15} [get_ports {adc_data[8]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D17} [get_ports {adc_data[7]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D16} [get_ports {adc_data[6]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D15} [get_ports {adc_data[5]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E15} [get_ports {adc_data[4]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D18} [get_ports {adc_data[3]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C19} [get_ports {adc_data[2]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E16} [get_ports {adc_data[1]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F16} [get_ports {adc_data[0]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G16} [get_ports adc_oeb_b]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G15} [get_ports adc_clk]

#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B22} [get_ports dac_clk]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B21} [get_ports dac_pd]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C22} [get_ports {da_data[13]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D22} [get_ports {da_data[12]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E19} [get_ports {da_data[11]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E20} [get_ports {da_data[10]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F19} [get_ports {da_data[9]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G19} [get_ports {da_data[8]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C18} [get_ports {da_data[7]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C17} [get_ports {da_data[6]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G17} [get_ports {da_data[5]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F17} [get_ports {da_data[4]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F18} [get_ports {da_data[3]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E18} [get_ports {da_data[2]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN H20} [get_ports {da_data[1]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN H19} [get_ports {da_data[0]}]


####################
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B16} [get_ports adc_otr]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B17} [get_ports adc_pdn]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A16} [get_ports {adc_data[13]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN A17} [get_ports {adc_data[12]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C20} [get_ports {adc_data[11]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D20} [get_ports {adc_data[10]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C15} [get_ports {adc_data[9]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B15} [get_ports {adc_data[8]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D16} [get_ports {adc_data[7]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D17} [get_ports {adc_data[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E15} [get_ports {adc_data[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D15} [get_ports {adc_data[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C19} [get_ports {adc_data[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D18} [get_ports {adc_data[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F16} [get_ports {adc_data[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E16} [get_ports {adc_data[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G15} [get_ports adc_oeb_b]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G16} [get_ports adc_clk]

#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA16} [get_ports dac_clk]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB16} [get_ports dac_pd]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA19} [get_ports {da_data[13]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y19} [get_ports {da_data[12]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB19} [get_ports {da_data[11]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB20} [get_ports {da_data[10]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB21} [get_ports {da_data[9]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA21} [get_ports {da_data[8]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB22} [get_ports {da_data[7]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA22} [get_ports {da_data[6]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y21} [get_ports {da_data[5]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y20} [get_ports {da_data[4]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W22} [get_ports {da_data[3]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V22} [get_ports {da_data[2]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN U22} [get_ports {da_data[1]}]
#set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN T22} [get_ports {da_data[0]}]

set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN L17} [get_ports uart_tx ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN M17} [get_ports uart_rx ]







