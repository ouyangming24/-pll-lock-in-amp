
#æ—¶åºçº¦æŸ
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

#IOç®¡è„šçº¦æŸ
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN M19} [get_ports sys_clk]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN J20} [get_ports sys_rst_n]


# å‡è®¾æ‚¨çš„æ—¶é’Ÿå? sys_clkï¼Œæ”¾å®? IIR æ¨¡å—å†…çš„å»ºç«‹æ—¶é—´æ£?æŸ¥åˆ° 2 ä¸ªå‘¨æœ?
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


# --- å¼ƒç”¨ (2026-05) ----------------------------------------------------------
# æ—§å¼•è„šåˆ†é…?: adc_clk_2 åœ? AA18, 14 æ ? data æ•£å¸ƒåœ? AB16~V22 (è·¨åº¦ 16~22 è¡?).
# çŽ°è±¡: ch3 ADC é‡‡æ ·æ³¢å½¢å¸¦è§„å¾‹æ??"é”¯é½¿", æŽ¨æµ‹æ˜? PCB èµ°çº¿é•¿åº¦å·?/14 ä½?
#       æ•°æ®çº? setup-hold è¾¹ç¼˜ç´Šä¹±æ‰?è‡? (ch1/2 ç”¨åŒä¸?ä»? ad_wave_rec ä»£ç æ— é”¯é½?).
# ä¿®å¤: æ”¹ç”¨é›†ä¸­åœ¨å³ä¸Šè§’ (V13~AB17) çš„ä¸€ç‰‡ç›¸é‚? IO, èµ°çº¿çŸ­ã?é•¿åº¦å·®å°?, æ³¢å½¢å¹²å‡€.
# ä¿ç•™ä»¥ä¸‹æ³¨é‡Šä½œä¸ºåŽ†å²å‚è??, ä¸è¦å†å¯ç”?.
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
# FT245BL USB-FIFO æŽ¥å£ (æ›¿ä»£åŽŸå…ˆçš? UART)
#   - FT245BL VCCIO å»ºè®®æŽ? 3.3 V, FPGA ç«? IOSTANDARD ç”? LVCMOS33
#   - ä¸‹é¢çš? PACKAGE_PIN å…¨æ˜¯ â˜…å ä½â˜…, å¿…é¡»æ ¹æ®å®žé™… PCB è¿žçº¿ä¿®æ”¹!
#   - åŽ? uart_tx(L17) / uart_rx(M17) çš? 2 ä¸ªå¼•è„šå·²é‡Šæ”¾, å¯ç”¨äºŽå…¶ä»–åŠŸèƒ?
#############################################################################

# ---- FIFO æ•°æ®æ€»çº¿ D0..D7 (åŒå‘) ------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN H20} [get_ports {ft_d[0]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F18} [get_ports {ft_d[1]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G17} [get_ports {ft_d[2]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C18} [get_ports {ft_d[3]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN F19} [get_ports {ft_d[4]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E19} [get_ports {ft_d[5]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN C22} [get_ports {ft_d[6]}]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B21} [get_ports {ft_d[7]}]

# ---- FIFO æŽ§åˆ¶ä¿¡å· ---------------------------------------------------------
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN B22} [get_ports ft_rd_n  ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN D22} [get_ports ft_wr    ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN E20} [get_ports ft_rxf_n ]
set_property -dict {IOSTANDARD LVCMOS33 PACKAGE_PIN G19} [get_ports ft_txe_n ]


# ---- æœªæŽ¥ FPGA çš? FT245 å¼•è„š (PCB å¤„ç†, ä¸åœ¨æ­¤çº¦æ?) -----------------------
#   FT245 PWREN# (pin 10) : è¾“å‡º, æœªä½¿ç”? -> æ‚¬ç©ºæˆ–æŽ¥ LED/æµ‹è¯•ç‚?
#   FT245 SI/WU  (pin 11) : è¾“å…¥, æœªä½¿ç”? -> PCB ä¸Šæ‹‰åˆ? VCCIO (å¼ºåˆ¶è¦æ±‚!)

# ---- å»ºè®®çš„æ—¶åº?/ç”µæ°”çº¦æŸ ---------------------------------------------------
# FT245 çš? FIFO æ—¶é’Ÿä¸Šé™ä¸? 48 MHz, æœ¬å·¥ç¨? sys_clk = 50 MHz å·²è¶³å¤Ÿæ…¢,
# è¯»å†™æ—¶åºç”? ft245_rx/ft245_tx å†…éƒ¨è®¡æ•°å™¨ä¿è¯?, é€šå¸¸ä¸éœ€è¦é¢å¤? SDC çº¦æŸã€?
# è‹¥ä»¥åŽåŠ å…¥æ›´é«˜é?Ÿçš„åŒæ­¥ FIFO (FT245BL ä¸æ”¯æŒ?), å†è¡¥ create_generated_clockã€?

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





