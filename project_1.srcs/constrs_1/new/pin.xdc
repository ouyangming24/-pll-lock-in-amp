
#�?�序约�?
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

# CDC: sys_clk(50MHz) and clk_wiz output 65MHz are asynchronous to each other.
#   usb_commend/FT245 run on sys_clk(50M); PLL/PSD/DDS run on clk_out1_clk_wiz_0(65M).
#   Multi-bit config buses between the two domains are double-registered in
#   lock_in_amp.v (CDC sync block). Declare async clock groups to remove the
#   bogus setup analysis on these crossings (was WNS ~= -16ns, 5000+ failing
#   endpoints, which made the open-loop PSDs latch corrupted frequency words).
set_clock_groups -asynchronous \
  -group [get_clocks sys_clk] \
  -group [get_clocks clk_out1_clk_wiz_0]

#IO管�??约�?
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN M19} [get_ports sys_clk]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN J20} [get_ports sys_rst_n]


# �?设�?��??�?��??�? sys_clk�?�?��? IIR 模�?�??�??建�?�?��?��?�?��?� 2 个�?��??
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


# --- �?�?� (2026-05) ----------------------------------------------------------
# �?��?�??�??�??: adc_clk_2 �?? AA18, 14 �? data �?��?�?? AB16~V22 (跨度 16~22 �?).
# �?�象: ch3 ADC �??样波形带�?�?�??"�?�齿", �?��?�?? PCB 走线�?�度�?/14 �?
#       �?�据�? setup-hold 边�?�?乱�??�?? (ch1/2 �?��?�?�? ad_wave_rec 代码�?��?��?).
# 修复: �?��?��??中�?�右�?�? (V13~AB17) �??�?�??�?��?? IO, 走线�?��?��?�度差�?, 波形干�??.
# 保�??以�?注�??�?为�??史�?�??, 不要�?�启�??.
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
# FT245BL USB-FIFO �?�口 (�?�代�??�??�?? UART)
#   - FT245BL VCCIO 建议�?? 3.3 V, FPGA �? IOSTANDARD �?? LVCMOS33
#   - �?面�?? PACKAGE_PIN �?��?� �??占位�??, �?须根据�?�?? PCB �?线修�?�!
#   - �?? uart_tx(L17) / uart_rx(M17) �?? 2 个�?�??已�??�?�, 可�?��?�?��?�??�??
#############################################################################

# ---- FIFO �?�据�?�线 D0..D7 (�?�?) ------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN H20} [get_ports {ft_d[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F18} [get_ports {ft_d[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G17} [get_ports {ft_d[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C18} [get_ports {ft_d[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F19} [get_ports {ft_d[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E19} [get_ports {ft_d[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C22} [get_ports {ft_d[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B21} [get_ports {ft_d[7]}]

# ---- FIFO �?��?�信号 ---------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B22} [get_ports ft_rd_n  ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D22} [get_ports ft_wr    ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E20} [get_ports ft_rxf_n ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G19} [get_ports ft_txe_n ]


# ---- �?��?� FPGA �?? FT245 �?�?? (PCB �?�?, 不�?�此约�?) -----------------------
#   FT245 PWREN# (pin 10) : �?�?�, �?�使�?? -> �?�空�??�?� LED/�?�?�??
#   FT245 SI/WU  (pin 11) : �?�?�, �?�使�?? -> PCB �?�??�?? VCCIO (强�?�要�?!)

# ---- 建议�??�?��?/�?��?约�? ---------------------------------------------------
# FT245 �?? FIFO �?��??�?�?��? 48 MHz, �?�工�? sys_clk = 50 MHz 已足�?�?�,
# 读�??�?�序�?? ft245_rx/ft245_tx �??�?�计�?��?�保�?, �??常不�??要额�? SDC 约�?�??
# �?�以�?�?��?��?��?�??�??�?步 FIFO (FT245BL 不�?��??), �?�补 create_generated_clock�??

#DAC 
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB16} [get_ports dac_pd]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA16} [get_ports dac_clk]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA19} [get_ports {da_data[13]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y19} [get_ports {da_data[12]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB19} [get_ports {da_data[11]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB20} [get_ports {da_data[10]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB21} [get_ports {da_data[9]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA21} [get_ports {da_data[8]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AB22} [get_ports {da_data[7]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN AA22} [get_ports {da_data[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y21} [get_ports {da_data[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN Y20} [get_ports {da_data[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN W22} [get_ports {da_data[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN V22} [get_ports {da_data[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN U22} [get_ports {da_data[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN T22} [get_ports {da_data[0]}]





