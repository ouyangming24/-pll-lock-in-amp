
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


# --- 弃用 (2026-05) ----------------------------------------------------------
# 旧引脚分配: adc_clk_2 在 AA18, 14 根 data 散布在 AB16~V22 (跨度 16~22 行).
# 现象: ch3 ADC 采样波形带规律性"锯齿", 推测是 PCB 走线长度差/14 位
#       数据线 setup-hold 边缘紊乱所致 (ch1/2 用同一份 ad_wave_rec 代码无锯齿).
# 修复: 改用集中在右上角 (V13~AB17) 的一片相邻 IO, 走线短、长度差小, 波形干净.
# 保留以下注释作为历史参考, 不要再启用.
# -----------------------------------------------------------------------------
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y18}  [get_ports adc_oeb_b_2]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA18} [get_ports adc_clk_2]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB16} [get_ports {adc_data_2[0]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA16} [get_ports {adc_data_2[1]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA19} [get_ports {adc_data_2[2]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y19}  [get_ports {adc_data_2[3]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB19} [get_ports {adc_data_2[4]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB20} [get_ports {adc_data_2[5]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB21} [get_ports {adc_data_2[6]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA21} [get_ports {adc_data_2[7]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB22} [get_ports {adc_data_2[8]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA22} [get_ports {adc_data_2[9]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y21} [get_ports {adc_data_2[10]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y20} [get_ports {adc_data_2[11]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W22} [get_ports {adc_data_2[12]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V22} [get_ports {adc_data_2[13]}]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN U22}  [get_ports adc_pdn_2]
# set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN T22}  [get_ports adc_otr_2]


set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V15}  [get_ports adc_oeb_b_2]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V14} [get_ports adc_clk_2]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y14} [get_ports {adc_data_2[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA14} [get_ports {adc_data_2[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W16} [get_ports {adc_data_2[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y16}  [get_ports {adc_data_2[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA17} [get_ports {adc_data_2[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB17} [get_ports {adc_data_2[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W18} [get_ports {adc_data_2[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W17} [get_ports {adc_data_2[7]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V13} [get_ports {adc_data_2[8]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W13} [get_ports {adc_data_2[9]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y13} [get_ports {adc_data_2[10]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA13} [get_ports {adc_data_2[11]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB14} [get_ports {adc_data_2[12]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB15} [get_ports {adc_data_2[13]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y18}  [get_ports adc_pdn_2]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA18}  [get_ports adc_otr_2]




#############################################################################
# FT245BL USB-FIFO 接口 (替代原先的 UART)
#   - FT245BL VCCIO 建议接 3.3 V, FPGA 端 IOSTANDARD 用 LVCMOS33
#   - 下面的 PACKAGE_PIN 全是 ★占位★, 必须根据实际 PCB 连线修改!
#   - 原 uart_tx(L17) / uart_rx(M17) 的 2 个引脚已释放, 可用于其他功能
#############################################################################

# ---- FIFO 数据总线 D0..D7 (双向) ------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN H20} [get_ports {ft_d[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F18} [get_ports {ft_d[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G17} [get_ports {ft_d[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C18} [get_ports {ft_d[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F19} [get_ports {ft_d[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E19} [get_ports {ft_d[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C22} [get_ports {ft_d[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B21} [get_ports {ft_d[7]}]

# ---- FIFO 控制信号 ---------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B22} [get_ports ft_rd_n  ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D22} [get_ports ft_wr    ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E20} [get_ports ft_rxf_n ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G19} [get_ports ft_txe_n ]


# ---- 未接 FPGA 的 FT245 引脚 (PCB 处理, 不在此约束) -----------------------
#   FT245 PWREN# (pin 10) : 输出, 未使用 -> 悬空或接 LED/测试点
#   FT245 SI/WU  (pin 11) : 输入, 未使用 -> PCB 上拉到 VCCIO (强制要求!)

# ---- 建议的时序/电气约束 ---------------------------------------------------
# FT245 的 FIFO 时钟上限为 48 MHz, 本工程 sys_clk = 50 MHz 已足够慢,
# 读写时序由 ft245_rx/ft245_tx 内部计数器保证, 通常不需要额外 SDC 约束。
# 若以后加入更高速的同步 FIFO (FT245BL 不支持), 再补 create_generated_clock。







