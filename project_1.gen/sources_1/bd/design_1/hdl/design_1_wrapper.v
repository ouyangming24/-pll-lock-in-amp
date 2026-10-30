//Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
//Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
//--------------------------------------------------------------------------------
//Tool Version: Vivado v.2025.1 (win64) Build 6140274 Thu May 22 00:12:29 MDT 2025
//Date        : Thu Oct 29 12:25:14 2026
//Host        : DESKTOP-PEDBCMF running 64-bit major release  (build 9200)
//Command     : generate_target design_1_wrapper.bd
//Design      : design_1_wrapper
//Purpose     : IP block netlist
//--------------------------------------------------------------------------------
`timescale 1 ps / 1 ps

module design_1_wrapper
   (DDR_addr,
    DDR_ba,
    DDR_cas_n,
    DDR_ck_n,
    DDR_ck_p,
    DDR_cke,
    DDR_cs_n,
    DDR_dm,
    DDR_dq,
    DDR_dqs_n,
    DDR_dqs_p,
    DDR_odt,
    DDR_ras_n,
    DDR_reset_n,
    DDR_we_n,
    FIXED_IO_ddr_vrn,
    FIXED_IO_ddr_vrp,
    FIXED_IO_mio,
    FIXED_IO_ps_clk,
    FIXED_IO_ps_porb,
    FIXED_IO_ps_srstb,
    ad_busy_0,
    ad_convst_0,
    ad_cs_n_0,
    ad_db_0,
    ad_frstdata_0,
    ad_os_0,
    ad_rd_n_0,
    ad_reset_0,
    ad_wr_n_0,
    da_data_0,
    dac_clk_0,
    dac_pd_0,
    pl_led1_0,
    pl_led2_0,
    sys_clk_0,
    sys_rst_n_0,
    uart_rxd_0,
    uart_txd_0);
  inout [14:0]DDR_addr;
  inout [2:0]DDR_ba;
  inout DDR_cas_n;
  inout DDR_ck_n;
  inout DDR_ck_p;
  inout DDR_cke;
  inout DDR_cs_n;
  inout [3:0]DDR_dm;
  inout [31:0]DDR_dq;
  inout [3:0]DDR_dqs_n;
  inout [3:0]DDR_dqs_p;
  inout DDR_odt;
  inout DDR_ras_n;
  inout DDR_reset_n;
  inout DDR_we_n;
  inout FIXED_IO_ddr_vrn;
  inout FIXED_IO_ddr_vrp;
  inout [53:0]FIXED_IO_mio;
  inout FIXED_IO_ps_clk;
  inout FIXED_IO_ps_porb;
  inout FIXED_IO_ps_srstb;
  input ad_busy_0;
  output ad_convst_0;
  output ad_cs_n_0;
  inout [15:0]ad_db_0;
  input ad_frstdata_0;
  output [2:0]ad_os_0;
  output ad_rd_n_0;
  output ad_reset_0;
  output ad_wr_n_0;
  output [13:0]da_data_0;
  output dac_clk_0;
  output dac_pd_0;
  output pl_led1_0;
  output pl_led2_0;
  input sys_clk_0;
  input sys_rst_n_0;
  input uart_rxd_0;
  output uart_txd_0;

  wire [14:0]DDR_addr;
  wire [2:0]DDR_ba;
  wire DDR_cas_n;
  wire DDR_ck_n;
  wire DDR_ck_p;
  wire DDR_cke;
  wire DDR_cs_n;
  wire [3:0]DDR_dm;
  wire [31:0]DDR_dq;
  wire [3:0]DDR_dqs_n;
  wire [3:0]DDR_dqs_p;
  wire DDR_odt;
  wire DDR_ras_n;
  wire DDR_reset_n;
  wire DDR_we_n;
  wire FIXED_IO_ddr_vrn;
  wire FIXED_IO_ddr_vrp;
  wire [53:0]FIXED_IO_mio;
  wire FIXED_IO_ps_clk;
  wire FIXED_IO_ps_porb;
  wire FIXED_IO_ps_srstb;
  wire ad_busy_0;
  wire ad_convst_0;
  wire ad_cs_n_0;
  wire [15:0]ad_db_0;
  wire ad_frstdata_0;
  wire [2:0]ad_os_0;
  wire ad_rd_n_0;
  wire ad_reset_0;
  wire ad_wr_n_0;
  wire [13:0]da_data_0;
  wire dac_clk_0;
  wire dac_pd_0;
  wire pl_led1_0;
  wire pl_led2_0;
  wire sys_clk_0;
  wire sys_rst_n_0;
  wire uart_rxd_0;
  wire uart_txd_0;

  design_1 design_1_i
       (.DDR_addr(DDR_addr),
        .DDR_ba(DDR_ba),
        .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n),
        .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p),
        .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n),
        .DDR_reset_n(DDR_reset_n),
        .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
        .ad_busy_0(ad_busy_0),
        .ad_convst_0(ad_convst_0),
        .ad_cs_n_0(ad_cs_n_0),
        .ad_db_0(ad_db_0),
        .ad_frstdata_0(ad_frstdata_0),
        .ad_os_0(ad_os_0),
        .ad_rd_n_0(ad_rd_n_0),
        .ad_reset_0(ad_reset_0),
        .ad_wr_n_0(ad_wr_n_0),
        .da_data_0(da_data_0),
        .dac_clk_0(dac_clk_0),
        .dac_pd_0(dac_pd_0),
        .pl_led1_0(pl_led1_0),
        .pl_led2_0(pl_led2_0),
        .sys_clk_0(sys_clk_0),
        .sys_rst_n_0(sys_rst_n_0),
        .uart_rxd_0(uart_rxd_0),
        .uart_txd_0(uart_txd_0));
endmodule
