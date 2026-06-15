`timescale 1ns / 1ps
// =============================================================================
//  lock_in_amp.v   ─── 双通道数字锁相放大器顶层
//
//  [v3.2 重构]
//   1) 把"锁相环 (PLL)"和"锁相放大器 (PSD)"各自封装为独立模块:
//        - pll_loop.v    : 闭环 PLL (ADC 信号 → 锁定频率字 + X/Y)
//        - lockin_psd.v  : 开环 PSD (外部参考频率 → X/Y)
//   2) F2 现在通过 adc_ch2 真正闭环锁定:
//        - 通道2 PLL 跟踪 adc_ch2 → pll_freq_ch2
//        - 三个和差频 DDS 改用 pll_freq_ch2 (而不是 tx2_freq_word)
//   3) tx1_freq_word / tx2_freq_word 仍保留为 PLL 扫频起点
// =============================================================================

module lock_in_amp(
    input                 sys_clk     ,
    input                 sys_rst_n   ,

   //AD 芯片接口 (锁定通道1/2)
   input   wire  [13:0]  adc_data    ,
   input   wire          adc_otr     ,
   output  wire          adc_pdn     ,
   output  wire          adc_oeb_b   ,
   output  wire          adc_clk     ,

   //AD_2 芯片接口 (通道3 相敏检测)
   input   wire  [13:0]  adc_data_2    ,
   input   wire          adc_otr_2     ,
   output  wire          adc_pdn_2     ,
   output  wire          adc_oeb_b_2   ,
   output  wire          adc_clk_2     ,

   // FT245BL USB 接口 (保留作为下行命令通道; 也可作为上行备份)
   inout  wire [7:0] ft_d,
   input  wire       ft_rxf_n,
   output wire       ft_rd_n,
   input  wire       ft_txe_n,
   output wire       ft_wr,

   // ★ 新增: 千兆以太网 (RTL8211E, RGMII 接 PL 端)
   //   注: 50 MHz 基准时钟复用现有 sys_clk (XDC = M19)
   input  wire       eth_rxc,
   input  wire       eth_rxctl,
   input  wire [3:0] eth_rxd,
   output wire       eth_txc,
   output wire       eth_txctl,
   output wire [3:0] eth_txd,
   output wire       eth_nrst,
   output wire       eth_mdc,
   inout  wire       eth_mdio,

   // ★ 新增: PL LED 状态指示 (可选, 不接也行)
   output wire       pl_led1,    // 链路状态: 长亮=1G 已链上
   output wire       pl_led2,    // 帧丢失指示: 闪烁=有帧被丢弃

   // ★ 新增: 信号发生器 DAC904 接口
   output wire        dac_pd,    // DAC 掉电控制 (da_wave_send 内固定为 0)
   output wire        dac_clk,   // DAC 采样时钟 (= clk_65M)
   output wire [13:0] da_data    // DAC 数据 (offset binary, 14bit)
);

// =========================================================================
// 命名约定:
//   adc_chN  : ADC 采样后的输入信号
//   pll_freq_chN : 通道N PLL 锁定后的频率字
//   dc_x_chN / dc_y_chN : 通道N 锁相输出 (28 bit signed)
//   _21 / _12 / _11 : 通道3 在 (2F1+F2)/(F1+2F2)/(F1+F2) 频点的解调
//   _ch3_dc : 通道3 的直流分量
// =========================================================================

assign sys_rst = ~sys_rst_n;

wire [13:0] adc_ch1, adc_ch2, adc_ch3, adc_ch4;

// ─── 时钟 ──────────────────────────────────────────────────────────────────
wire clk_65M, clk_locked;
clk_wiz_0 u_clk_wiz_0 (
    .clk_out1 (clk_65M),
    .reset    (sys_rst),
    .locked   (clk_locked),
    .clk_in1  (sys_clk)
);

// ─── 上位机参数 (原始: sys_clk=50M 域, 由 usb_commend 驱动, 后缀 _w) ─────────
wire pll_en = 1'b1;
wire [47:0] center_freq_uart;       // FREQ 命令 (当前未用于 PLL, 保留直连)
wire [15:0] pll_kp_w;
wire [15:0] pll_ki_w;
wire [4:0]  tau1_x_w, tau1_y_w, tau2_x_w, tau2_y_w;
// ch3 谐波/DC IIR 时间常数 (X/Y 共用, 与商用 SR830 等保持一致)
wire [4:0]  tau21_w, tau12_w, tau11_w, tau_dc_w;
wire [47:0] tx1_phase_word;         // (仅注释掉的 tx DDS 用, 不跨域消费)
wire [47:0] tx1_freq_word_w;
wire [47:0] tx2_phase_word = 48'd0;
wire [47:0] tx2_freq_word_w;
// ★ 通道3 三路振荡器 ref_freq
//   REFMODE=0: 手动, 频率字由 FRQ21/FRQ12/FRQ11 下发
//   REFMODE=1: 自动, 硬件实时 n*pll_freq_ch1 + m*pll_freq_ch2 (系数 OSC1/2/3)
wire [47:0] freq_word_21_w, freq_word_12_w, freq_word_11_w;
wire        ref_freq_auto_w;        // REFMODE: 0=手动 / 1=自动
wire [7:0]  osc1_n_w, osc1_m_w, osc2_n_w, osc2_m_w, osc3_n_w, osc3_m_w;
// ★ 三路振荡器输入源 (OSRC1/2/3: 0=CH3, 1=CH4, 2=CH3-CH4)
wire [1:0]  osc1_src_w, osc2_src_w, osc3_src_w;
// ★ 通道3 4 路 IIR 阶数 (各路独立, ORD21/ORD12/ORD11/ORDDC 命令: 1..4)
wire [2:0]  order21_w, order12_w, order11_w, order_dc_w;
// ★ PLL 锁定阈值 (由 USB 命令 LOCKSWY/LOCKTHX 动态下发)
wire signed [27:0] sweep_thres_w, lock_x_thres_w;
// ★ 信号发生器 (DAC904) 控制 (DMOD/DFRQ/DPHS/DAMP/DOFS, 已有独立 CDC 同步, 见下方 DAC 块)
wire [2:0]  dac_src_mode_uart;     // 0=内部DDS / 1=跟随CH1 / 2=跟随CH2 / 3/4/5=跟随振荡器1/2/3
wire [47:0] dac_freq_word_uart;    // 内部DDS频率字
wire [47:0] dac_phase_word_uart;   // 内部DDS相位字
wire signed [15:0] dac_amp_uart;   // 峰值幅度 (LSB, 0..8192)
wire signed [15:0] dac_offset_uart;// 直流偏置 (LSB, 有符号)
// ★ 三路振荡器实际混频参考正弦 (由各 lockin_psd 导出, 供 DAC "跟随振荡器" 同步输出)
wire signed [13:0] osc1_ref_sine, osc2_ref_sine, osc3_ref_sine;

// =========================================================================
// ★ 跨时钟域同步 (sys_clk 50M → clk_65M)
//
//   PLL 参数走窄总线 (204bit) 两拍同步; 振荡器/CH3 参数逐字段双触发器同步.
//   435bit 宽总线曾导致 bit-skew → 某路 OSC 系数变 0 → 振荡器3 恒为 0.
//   配套约束: pin.xdc set_clock_groups -asynchronous (sys_clk ↔ 65M).
// =========================================================================
wire [15:0] pll_kp, pll_ki;
wire [47:0] tx1_freq_word, tx2_freq_word;
wire [4:0]  tau1_x_uart, tau1_y_uart, tau2_x_uart, tau2_y_uart;
wire signed [27:0] sweep_thres_uart, lock_x_thres_uart;

// CH3 / 振荡器: 逐字段同步后的稳定值 (reg, 在下方 always 块赋值)
reg [4:0]  tau21_uart, tau12_uart, tau11_uart, tau_dc_uart;
reg [47:0] freq_word_21_uart, freq_word_12_uart, freq_word_11_uart;
reg        ref_freq_auto_uart;
reg [7:0]  osc1_n_uart, osc1_m_uart, osc2_n_uart, osc2_m_uart;
reg [7:0]  osc3_n_uart, osc3_m_uart;
reg [1:0]  osc1_src_uart, osc2_src_uart, osc3_src_uart;
reg [2:0]  order21_uart, order12_uart, order11_uart, order_dc_uart;

localparam CFG_PLL_W = 16+16 +48+48 +5+5+5+5 +28+28; // = 204
localparam [47:0] CFG_DEF_TX1 = 48'd433038425708 + 48'd433038425;
localparam [47:0] CFG_DEF_TX2 = 48'd519646110;
localparam [CFG_PLL_W-1:0] CFG_PLL_DEFAULT = {
    16'd500, 16'd50,
    CFG_DEF_TX1, CFG_DEF_TX2,
    5'd20, 5'd8, 5'd20, 5'd8,
    28'sd100_000, 28'sd300_000
};
wire [CFG_PLL_W-1:0] cfg_pll_raw = {
    pll_kp_w, pll_ki_w,
    tx1_freq_word_w, tx2_freq_word_w,
    tau1_x_w, tau1_y_w, tau2_x_w, tau2_y_w,
    sweep_thres_w, lock_x_thres_w
};
reg [CFG_PLL_W-1:0] cfg_pll_meta, cfg_pll_sync;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        cfg_pll_meta <= CFG_PLL_DEFAULT;
        cfg_pll_sync <= CFG_PLL_DEFAULT;
    end else begin
        cfg_pll_meta <= cfg_pll_raw;
        cfg_pll_sync <= cfg_pll_meta;
    end
end
assign {
    pll_kp, pll_ki,
    tx1_freq_word, tx2_freq_word,
    tau1_x_uart, tau1_y_uart, tau2_x_uart, tau2_y_uart,
    sweep_thres_uart, lock_x_thres_uart
} = cfg_pll_sync;

// 振荡器 / CH3 专用 CDC: 每字段独立双触发器 (消除宽总线 bit-skew)
reg        ref_auto_meta;
reg [4:0]  tau21_meta, tau12_meta, tau11_meta, tau_dc_meta;
reg [47:0] frq21_meta, frq12_meta, frq11_meta;
reg [7:0]  o1n_meta, o1m_meta, o2n_meta, o2m_meta, o3n_meta, o3m_meta;
reg [1:0]  os1_meta, os2_meta, os3_meta;
reg [2:0]  ord21_meta, ord12_meta, ord11_meta, ord_dc_meta;

always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        ref_freq_auto_uart <= 1'b1;
        tau21_uart <= 5'd2;  tau12_uart <= 5'd2;
        tau11_uart <= 5'd2;  tau_dc_uart <= 5'd2;
        freq_word_21_uart <= 48'd692861481134;
        freq_word_12_uart <= 48'd736165323705;
        freq_word_11_uart <= 48'd476342268280;
        osc1_n_uart <= 8'd2;  osc1_m_uart <= 8'd1;
        osc2_n_uart <= 8'd1;  osc2_m_uart <= 8'd2;
        osc3_n_uart <= 8'd1;  osc3_m_uart <= 8'd1;
        osc1_src_uart <= 2'd0; osc2_src_uart <= 2'd0; osc3_src_uart <= 2'd0;
        order21_uart <= 3'd1; order12_uart <= 3'd1;
        order11_uart <= 3'd1; order_dc_uart <= 3'd1;
    end else begin
        ref_auto_meta   <= ref_freq_auto_w;
        ref_freq_auto_uart <= ref_auto_meta;
        tau21_meta <= tau21_w;   tau21_uart <= tau21_meta;
        tau12_meta <= tau12_w;   tau12_uart <= tau12_meta;
        tau11_meta <= tau11_w;   tau11_uart <= tau11_meta;
        tau_dc_meta <= tau_dc_w; tau_dc_uart <= tau_dc_meta;
        frq21_meta <= freq_word_21_w; freq_word_21_uart <= frq21_meta;
        frq12_meta <= freq_word_12_w; freq_word_12_uart <= frq12_meta;
        frq11_meta <= freq_word_11_w; freq_word_11_uart <= frq11_meta;
        o1n_meta <= osc1_n_w; osc1_n_uart <= o1n_meta;
        o1m_meta <= osc1_m_w; osc1_m_uart <= o1m_meta;
        o2n_meta <= osc2_n_w; osc2_n_uart <= o2n_meta;
        o2m_meta <= osc2_m_w; osc2_m_uart <= o2m_meta;
        o3n_meta <= osc3_n_w; osc3_n_uart <= o3n_meta;
        o3m_meta <= osc3_m_w; osc3_m_uart <= o3m_meta;
        os1_meta <= osc1_src_w; osc1_src_uart <= os1_meta;
        os2_meta <= osc2_src_w; osc2_src_uart <= os2_meta;
        os3_meta <= osc3_src_w; osc3_src_uart <= os3_meta;
        ord21_meta <= order21_w; order21_uart <= ord21_meta;
        ord12_meta <= order12_w; order12_uart <= ord12_meta;
        ord11_meta <= order11_w; order11_uart <= ord11_meta;
        ord_dc_meta <= order_dc_w; order_dc_uart <= ord_dc_meta;
    end
end


// =========================================================================
// ★ AD 数据接收
// =========================================================================
ad_wave_rec u_ad_wave_rec (
   .CLK_65M   (clk_65M   ),
   .RST_N     (sys_rst_n ),
   .ADC_IN    (adc_data  ),
   .OTR       (adc_otr   ),
   .PDN       (adc_pdn   ),
   .OEB_B     (adc_oeb_b ),
   .ADC_CLK   (adc_clk   ),
   .ADC_OUTA  (adc_ch1   ),
   .ADC_OUTB  (adc_ch2   )
);

ad_wave_rec u_ad_wave_rec_2 (
   .CLK_65M   (clk_65M     ),
   .RST_N     (sys_rst_n   ),
   .ADC_IN    (adc_data_2  ),
   .OTR       (adc_otr_2   ),
   .PDN       (adc_pdn_2   ),
   .OEB_B     (adc_oeb_b_2 ),
   .ADC_CLK   (adc_clk_2   ),
   .ADC_OUTA  (adc_ch3     ),
   .ADC_OUTB  (adc_ch4     )
);


// =========================================================================
// ★ 通道1: 锁相环 (闭环 PLL)  —— 跟踪 adc_ch1 → 输出 F1 = pll_freq_ch1
// =========================================================================
wire [47:0]         pll_freq_ch1;
wire [47:0]         pll_phase_ch1;
wire signed [13:0]  pll_sin_ch1, pll_cos_ch1;
wire signed [27:0]  dc_x_ch1, dc_y_ch1;
wire                cic_valid_x_ch1, cic_valid_y_ch1;
wire                dc_valid_x_ch1,  dc_valid_y_ch1;
wire                is_locked_ch1;

// ★★★ 锁定阈值现在由上位机运行时下发, 不再是综合时常量 ★★★
//   命令: LOCKSWY:<n>  → sweep_thres  (Y 进 LOCK 门槛)
//        LOCKTHX:<n>  → lock_x_thres (X 维持 LOCK 门槛)
//   默认值在 usb_commend.v 复位时设为 100_000 / 300_000 (折中)
//
//   28 bit signed 信号在 14×14 混频 + CIC + IIR 后, 满量程量级 ≈ ±30 M.
//   ADC 噪声本底 ~800 K (取决于环境). 调参参考:
//     - 信号强 (≥ 25% 满量程) → SWEEP=800K, LOCK=3M
//     - 信号弱 (< 5% 满量程)  → SWEEP=20K,  LOCK=50K
//     - 不知道 / 中等          → SWEEP=100K, LOCK=300K (默认)
pll_loop #(
    .KI_FRAC      (16),
    .IN_WIDTH     (28)
) u_pll_ch1 (
    .clk          (clk_65M),
    .rst_n        (sys_rst_n),
    .pll_en       (pll_en),
    .adc_in       (adc_ch1),
    .center_freq  (tx1_freq_word),
    .pll_kp       (pll_kp),
    .pll_ki       (pll_ki),
    .tau_x        (tau1_x_uart),
    .tau_y        (tau1_y_uart),
    .sweep_thres  (sweep_thres_uart),
    .lock_x_thres (lock_x_thres_uart),
    .dds_freq_out (pll_freq_ch1),
    .dds_phase_out(pll_phase_ch1),
    .ref_sine_out (pll_sin_ch1),
    .ref_cos_out  (pll_cos_ch1),
    .dc_x         (dc_x_ch1),
    .dc_y         (dc_y_ch1),
    .cic_valid_x  (cic_valid_x_ch1),
    .cic_valid_y  (cic_valid_y_ch1),
    .dc_valid_x   (dc_valid_x_ch1),
    .dc_valid_y   (dc_valid_y_ch1),
    .is_locked    (is_locked_ch1)
);


// =========================================================================
// ★ 通道2: 锁相环 (闭环 PLL)  —— ★ 跟踪 adc_ch2 → 输出 F2 = pll_freq_ch2
// =========================================================================
wire [47:0]         pll_freq_ch2;
wire [47:0]         pll_phase_ch2;
wire signed [13:0]  pll_sin_ch2, pll_cos_ch2;
wire signed [27:0]  dc_x_ch2, dc_y_ch2;
wire                cic_valid_x_ch2, cic_valid_y_ch2;
wire                dc_valid_x_ch2,  dc_valid_y_ch2;
wire                is_locked_ch2;

pll_loop #(
    .KI_FRAC      (16),
    .IN_WIDTH     (28)
) u_pll_ch2 (
    .clk          (clk_65M),
    .rst_n        (sys_rst_n),
    .pll_en       (pll_en),
    .adc_in       (adc_ch2),
    .center_freq  (tx2_freq_word),     // 扫频起点 (FRQ3 指令设置)
    .pll_kp       (pll_kp),
    .pll_ki       (pll_ki),
    .tau_x        (tau2_x_uart),
    .tau_y        (tau2_y_uart),
    .sweep_thres  (sweep_thres_uart),    // ★ 两通道共用阈值
    .lock_x_thres (lock_x_thres_uart),
    .dds_freq_out (pll_freq_ch2),
    .dds_phase_out(pll_phase_ch2),
    .ref_sine_out (pll_sin_ch2),
    .ref_cos_out  (pll_cos_ch2),
    .dc_x         (dc_x_ch2),
    .dc_y         (dc_y_ch2),
    .cic_valid_x  (cic_valid_x_ch2),
    .cic_valid_y  (cic_valid_y_ch2),
    .dc_valid_x   (dc_valid_x_ch2),
    .dc_valid_y   (dc_valid_y_ch2),
    .is_locked    (is_locked_ch2)
);


// PLL 本振 sin/cos 打一拍 (DAC 跟随 / 相干谐波合成共用)
reg signed [13:0] pll_sin1_r, pll_cos1_r, pll_sin2_r, pll_cos2_r;
always @(posedge clk_65M) begin
    pll_sin1_r <= pll_sin_ch1;
    pll_cos1_r <= pll_cos_ch1;
    pll_sin2_r <= pll_sin_ch2;
    pll_cos2_r <= pll_cos_ch2;
end


// =========================================================================
// ★ 信号发生器 (DAC904)
//    输出可送 DAC, 频率即跟随 PLL 锁定结果
// =========================================================================
// wire [95:0]        dds_tx1_config = {tx1_phase_word, pll_freq_ch1};
// wire signed [31:0] tx1_sine_cos;
// wire signed [13:0] sine_tx1 = tx1_sine_cos[29:16];
// wire signed [13:0] cos_tx1  = tx1_sine_cos[13:0];

// dds_compiler_1 u_dds_tx1 (
//     .aclk                  (clk_65M),
//     .s_axis_config_tvalid  (1'b1),
//     .s_axis_config_tdata   (dds_tx1_config),
//     .m_axis_data_tvalid    (),
//     .m_axis_data_tdata     (tx1_sine_cos),
//     .m_axis_phase_tvalid   (),
//     .m_axis_phase_tdata    ()
// );

// wire [95:0]        dds_tx2_config = {tx2_phase_word, pll_freq_ch2};
// wire signed [31:0] tx2_sine_cos;
// wire signed [13:0] sine_tx2 = tx2_sine_cos[29:16];
// wire signed [13:0] cos_tx2  = tx2_sine_cos[13:0];

// dds_compiler_1 u_dds_tx2 (
//     .aclk                  (clk_65M),
//     .s_axis_config_tvalid  (1'b1),
//     .s_axis_config_tdata   (dds_tx2_config),
//     .m_axis_data_tvalid    (),
//     .m_axis_data_tdata     (tx2_sine_cos),
//     .m_axis_phase_tvalid   (),
//     .m_axis_phase_tdata    ()
// );


// =========================================================================
// ★ 信号发生器 (DAC904)  —— 内部 DDS / 跟随 CH1·CH2 锁定频率
//
//   频率字来源 (DMOD 命令选择):
//     0 = 内部 DDS : 频率/相位由上位机 DFRQ/DPHS 指定 (独立信号源)
//     1 = 跟随 CH1 : 频率字 = pll_freq_ch1 (与 CH1 外参考锁定结果同频输出)
//     2 = 跟随 CH2 : 频率字 = pll_freq_ch2
//   相位: 始终叠加 dac_phase_word_uart (DPHS), 跟随模式下用于微调相位对齐.
//
//   注: 跟随模式输出与输入"同频", 相位为本 DDS 自由相位 + DPHS 偏移; 若要与
//       输入信号严格同相, 需现场用 DPHS 标定 (或后续从 PLL NCO 直接引相位).
//
//   DFRQ/DMOD/DPHS 在 sys_clk(50M) 更新, DDS 在 clk_65M 运行 —— 必须先同步
//   再打拍, 且仅在配置变化时脉冲 s_axis_config_tvalid (勿恒为 1).
// =========================================================================
reg [2:0]  dac_src_mode_meta, dac_src_mode_sync, dac_src_mode_65m;
reg [47:0] dac_freq_word_meta, dac_freq_word_65m;
reg [47:0] dac_phase_word_meta, dac_phase_word_65m;
reg signed [15:0] dac_amp_meta, dac_amp_65m;
reg signed [15:0] dac_offset_meta, dac_offset_65m;

always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        dac_src_mode_meta  <= 3'd0;
        dac_src_mode_sync  <= 3'd0;
        dac_src_mode_65m   <= 3'd0;
        dac_freq_word_meta <= 48'd216519212854;   // 与 usb_commend 默认 ~50 kHz 一致
        dac_freq_word_65m  <= 48'd216519212854;
        dac_phase_word_meta <= 48'd0;
        dac_phase_word_65m  <= 48'd0;
        dac_amp_meta    <= 16'sd8192; dac_amp_65m    <= 16'sd8192;  // 默认满幅
        dac_offset_meta <= 16'sd0;    dac_offset_65m <= 16'sd0;
    end else begin
        dac_src_mode_meta  <= dac_src_mode_uart;
        dac_src_mode_sync  <= dac_src_mode_meta;
        dac_src_mode_65m   <= dac_src_mode_sync;
        dac_freq_word_meta <= dac_freq_word_uart;
        dac_freq_word_65m  <= dac_freq_word_meta;
        dac_phase_word_meta <= dac_phase_word_uart;
        dac_phase_word_65m  <= dac_phase_word_meta;
        dac_amp_meta    <= dac_amp_uart;    dac_amp_65m    <= dac_amp_meta;
        dac_offset_meta <= dac_offset_uart; dac_offset_65m <= dac_offset_meta;
    end
end

// 跟随 CH1/CH2 时频率字来自 PLL, 先打一拍再 mux, 避免 pll_freq → DDS 长路径
reg [47:0] pll_freq_ch1_dac_r, pll_freq_ch2_dac_r;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        pll_freq_ch1_dac_r <= 48'd0;
        pll_freq_ch2_dac_r <= 48'd0;
    end else begin
        pll_freq_ch1_dac_r <= pll_freq_ch1;
        pll_freq_ch2_dac_r <= pll_freq_ch2;
    end
end

wire [47:0] dac_freq_sel = (dac_src_mode_65m == 3'd1) ? pll_freq_ch1_dac_r :
                           (dac_src_mode_65m == 3'd2) ? pll_freq_ch2_dac_r :
                                                         dac_freq_word_65m;

// DDS 配置: 与 pll_loop 相同 —— 每拍 tvalid=1, 频率/相位仅在变化时更新 hold 寄存器
wire        dac_in_follow = (dac_src_mode_65m == 3'd1) || (dac_src_mode_65m == 3'd2);
wire [47:0] dac_freq_target = dac_freq_sel;

reg [47:0] dac_freq_hold;
reg [47:0] dac_phase_hold;
reg [2:0]  dac_src_mode_hold;

wire dac_freq_changed = dac_in_follow ?
    (dac_freq_target[47:20] != dac_freq_hold[47:20]) :
    (dac_freq_target != dac_freq_hold);
wire dac_phase_changed = (dac_phase_word_65m != dac_phase_hold);
wire dac_mode_changed  = (dac_src_mode_65m != dac_src_mode_hold);

always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        dac_freq_hold      <= 48'd216519212854;
        dac_phase_hold     <= 48'd0;
        dac_src_mode_hold  <= 3'd0;
    end else if (dac_mode_changed || dac_freq_changed || dac_phase_changed) begin
        dac_freq_hold     <= dac_freq_target;
        dac_phase_hold    <= dac_phase_word_65m;
        dac_src_mode_hold <= dac_src_mode_65m;
    end
end

wire [95:0] dac_dds_cfg = {dac_phase_hold, dac_freq_hold};

wire signed [31:0] dac_sine_cos;

dds_compiler_1 u_dds_dac (
    .aclk                  (clk_65M),
    .s_axis_config_tvalid  (1'b1),
    .s_axis_config_tdata   (dac_dds_cfg),
    .m_axis_data_tvalid    (),
    .m_axis_data_tdata     (dac_sine_cos),
    .m_axis_phase_tvalid   (),
    .m_axis_phase_tdata    ()
);

wire signed [13:0] dac_sine = dac_sine_cos[29:16];

// ★ 信号源选择: 0/1/2 用内部DDS (dac_sine), 3/4/5 直接用振荡器1/2/3 的混频参考正弦
//   振荡器 ref_sine 来自 PSD 深路径, 先寄存再 mux, 避免跨模块长组合路径压时序.
reg signed [13:0] osc1_ref_sine_r, osc2_ref_sine_r, osc3_ref_sine_r;
reg signed [13:0] dac_sine_r;
reg [2:0]         dac_src_mode_wave_r;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        osc1_ref_sine_r     <= 14'sd0;
        osc2_ref_sine_r     <= 14'sd0;
        osc3_ref_sine_r     <= 14'sd0;
        dac_sine_r          <= 14'sd0;
        dac_src_mode_wave_r <= 3'd0;
    end else begin
        osc1_ref_sine_r     <= osc1_ref_sine;
        osc2_ref_sine_r     <= osc2_ref_sine;
        osc3_ref_sine_r     <= osc3_ref_sine;
        dac_sine_r          <= dac_sine;
        dac_src_mode_wave_r <= dac_src_mode_65m;
    end
end

wire signed [13:0] dac_osc_sine = (dac_src_mode_wave_r == 3'd3) ? osc1_ref_sine_r :
                                  (dac_src_mode_wave_r == 3'd4) ? osc2_ref_sine_r :
                                                                  osc3_ref_sine_r;
wire signed [13:0] dac_pll_sine = (dac_src_mode_wave_r == 3'd1) ? pll_sin1_r :
                                  (dac_src_mode_wave_r == 3'd2) ? pll_sin2_r :
                                                                  dac_sine_r;
wire signed [13:0] dac_src_wave = (dac_src_mode_wave_r >= 3'd3) ? dac_osc_sine : dac_pll_sine;

// ★ 幅值/偏置: 满量程 ±3V ↔ ±8192 LSB. 缩放 = wave*amp>>13 (amp=8192 即满幅),
//   再叠加偏置, 最后饱和到 14bit. 流水两拍打断乘加, 不压时序.
reg signed [13:0] dac_src_wave_r;
reg signed [16:0] dac_scaled_r;
reg signed [17:0] dac_sum_r;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        dac_src_wave_r <= 14'sd0;
        dac_scaled_r   <= 17'sd0;
        dac_sum_r      <= 18'sd0;
    end else begin
        dac_src_wave_r <= dac_src_wave;
        dac_scaled_r   <= (dac_src_wave_r * dac_amp_65m) >>> 13;   // 峰值≈dac_amp
        dac_sum_r      <= dac_scaled_r + dac_offset_65m;
    end
end

wire signed [13:0] dac_sat = (dac_sum_r >  18'sd8191) ?  14'sd8191 :
                             (dac_sum_r < -18'sd8192) ? -14'sd8192 :
                                                         dac_sum_r[13:0];

// signed [13:0] (-8192..8191) → offset binary (0..16383), 喂给 DAC904.
// 翻转 MSB 等价于 +8192, 且不会有 14'sd8192 溢出问题.
wire [13:0] dac_wave = {~dac_sat[13], dac_sat[12:0]};

da_wave_send u_da_wave_send (
    .CLK_DAC904 (clk_65M),
    .SYS_RST    (sys_rst),
    .DATA_BUF   (dac_wave),
    .PD         (dac_pd),
    .DAC_CLK    (dac_clk),
    .DAC_DATA   (da_data)
);


// =========================================================================
// ★ 通道3 锁相放大器 (PSD × 3 振荡器 + DC 通路)
// =========================================================================
// ★ 通道3 ref_freq 来源 mux
//
//   REFMODE = 0 (手动): ref_freq = FRQ21 / FRQ12 / FRQ11, 内部独立 DDS
//   REFMODE = 1 (自动): 相干本振 sin(n·θ1+m·θ2), θ1/θ2 来自 CH1/CH2 PLL 本振相位
//                       系数 n,m 由 OSC1/OSC2/OSC3 下发
// =========================================================================

// n=m=0 时相干本振恒为 sin(0); CDC 偶发错位时防呆回退到各振荡器默认系数
wire [7:0] osc1_n_eff = (osc1_n_uart == 8'd0 && osc1_m_uart == 8'd0) ? 8'd2 : osc1_n_uart;
wire [7:0] osc1_m_eff = (osc1_n_uart == 8'd0 && osc1_m_uart == 8'd0) ? 8'd1 : osc1_m_uart;
wire [7:0] osc2_n_eff = (osc2_n_uart == 8'd0 && osc2_m_uart == 8'd0) ? 8'd1 : osc2_n_uart;
wire [7:0] osc2_m_eff = (osc2_n_uart == 8'd0 && osc2_m_uart == 8'd0) ? 8'd2 : osc2_m_uart;
wire [7:0] osc3_n_eff = (osc3_n_uart == 8'd0 && osc3_m_uart == 8'd0) ? 8'd1 : osc3_n_uart;
wire [7:0] osc3_m_eff = (osc3_n_uart == 8'd0 && osc3_m_uart == 8'd0) ? 8'd1 : osc3_m_uart;

// ★ 自动模式参考频率 n*F1+m*F2: 48×8 乘加, 在 clk_65M 域寄存一拍打断长路径
//   (配置准静态, 加 1 拍延迟无影响; 自动模式 PSD 实际用相干本振混频, 此频率字
//    仅配置其内部 DDS, 不在临界采样路径上).
reg [55:0] f_osc1_auto, f_osc2_auto, f_osc3_auto;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        f_osc1_auto <= 56'd0;
        f_osc2_auto <= 56'd0;
        f_osc3_auto <= 56'd0;
    end else begin
        f_osc1_auto <= pll_freq_ch1 * osc1_n_eff + pll_freq_ch2 * osc1_m_eff;
        f_osc2_auto <= pll_freq_ch1 * osc2_n_eff + pll_freq_ch2 * osc2_m_eff;
        f_osc3_auto <= pll_freq_ch1 * osc3_n_eff + pll_freq_ch2 * osc3_m_eff;
    end
end

wire [47:0] ref_freq_21_comb = ref_freq_auto_uart ? f_osc1_auto[47:0] : freq_word_21_uart;
wire [47:0] ref_freq_12_comb = ref_freq_auto_uart ? f_osc2_auto[47:0] : freq_word_12_uart;
wire [47:0] ref_freq_11_comb = ref_freq_auto_uart ? f_osc3_auto[47:0] : freq_word_11_uart;

reg [47:0] ref_freq_21_to_psd, ref_freq_12_to_psd, ref_freq_11_to_psd;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        ref_freq_21_to_psd <= 48'd0;
        ref_freq_12_to_psd <= 48'd0;
        ref_freq_11_to_psd <= 48'd0;
    end else begin
        ref_freq_21_to_psd <= ref_freq_21_comb;
        ref_freq_12_to_psd <= ref_freq_12_comb;
        ref_freq_11_to_psd <= ref_freq_11_comb;
    end
end

// ---- 相干谐波本振: 由 PLL 本振 sin/cos 合成 sin(n·θ1+m·θ2) ------------------
wire signed [13:0] coh_sin_osc1, coh_cos_osc1;
wire signed [13:0] coh_sin_osc2, coh_cos_osc2;
wire signed [13:0] coh_sin_osc3, coh_cos_osc3;

coherent_harm_lo u_coh_lo_osc1 (
    .clk    (clk_65M),
    .sin1   (pll_sin1_r),
    .cos1   (pll_cos1_r),
    .sin2   (pll_sin2_r),
    .cos2   (pll_cos2_r),
    .harm_n (osc1_n_eff),
    .harm_m (osc1_m_eff),
    .harm_sine (coh_sin_osc1),
    .harm_cos  (coh_cos_osc1)
);

coherent_harm_lo u_coh_lo_osc2 (
    .clk    (clk_65M),
    .sin1   (pll_sin1_r),
    .cos1   (pll_cos1_r),
    .sin2   (pll_sin2_r),
    .cos2   (pll_cos2_r),
    .harm_n (osc2_n_eff),
    .harm_m (osc2_m_eff),
    .harm_sine (coh_sin_osc2),
    .harm_cos  (coh_cos_osc2)
);

coherent_harm_lo u_coh_lo_osc3 (
    .clk    (clk_65M),
    .sin1   (pll_sin1_r),
    .cos1   (pll_cos1_r),
    .sin2   (pll_sin2_r),
    .cos2   (pll_cos2_r),
    .harm_n (osc3_n_eff),
    .harm_m (osc3_m_eff),
    .harm_sine (coh_sin_osc3),
    .harm_cos  (coh_cos_osc3)
);

// 自动模式: n·m 为 1·F1 / 1·F2 时直接复用 PLL 本振 (与 CH1/CH2 相位/幅值一致)
wire signed [13:0] coh1_sin = (ref_freq_auto_uart && osc1_n_eff == 8'd1 && osc1_m_eff == 8'd0) ? pll_sin1_r :
                              (ref_freq_auto_uart && osc1_n_eff == 8'd0 && osc1_m_eff == 8'd1) ? pll_sin2_r :
                              coh_sin_osc1;
wire signed [13:0] coh1_cos = (ref_freq_auto_uart && osc1_n_eff == 8'd1 && osc1_m_eff == 8'd0) ? pll_cos1_r :
                              (ref_freq_auto_uart && osc1_n_eff == 8'd0 && osc1_m_eff == 8'd1) ? pll_cos2_r :
                              coh_cos_osc1;
wire signed [13:0] coh2_sin = (ref_freq_auto_uart && osc2_n_eff == 8'd1 && osc2_m_eff == 8'd0) ? pll_sin1_r :
                              (ref_freq_auto_uart && osc2_n_eff == 8'd0 && osc2_m_eff == 8'd1) ? pll_sin2_r :
                              coh_sin_osc2;
wire signed [13:0] coh2_cos = (ref_freq_auto_uart && osc2_n_eff == 8'd1 && osc2_m_eff == 8'd0) ? pll_cos1_r :
                              (ref_freq_auto_uart && osc2_n_eff == 8'd0 && osc2_m_eff == 8'd1) ? pll_cos2_r :
                              coh_cos_osc2;
wire signed [13:0] coh3_sin = (ref_freq_auto_uart && osc3_n_eff == 8'd1 && osc3_m_eff == 8'd0) ? pll_sin1_r :
                              (ref_freq_auto_uart && osc3_n_eff == 8'd0 && osc3_m_eff == 8'd1) ? pll_sin2_r :
                              coh_sin_osc3;
wire signed [13:0] coh3_cos = (ref_freq_auto_uart && osc3_n_eff == 8'd1 && osc3_m_eff == 8'd0) ? pll_cos1_r :
                              (ref_freq_auto_uart && osc3_n_eff == 8'd0 && osc3_m_eff == 8'd1) ? pll_cos2_r :
                              coh_cos_osc3;

wire coh1_pll_direct = ref_freq_auto_uart &&
    ((osc1_n_eff == 8'd1 && osc1_m_eff == 8'd0) || (osc1_n_eff == 8'd0 && osc1_m_eff == 8'd1));
wire coh2_pll_direct = ref_freq_auto_uart &&
    ((osc2_n_eff == 8'd1 && osc2_m_eff == 8'd0) || (osc2_n_eff == 8'd0 && osc2_m_eff == 8'd1));
wire coh3_pll_direct = ref_freq_auto_uart &&
    ((osc3_n_eff == 8'd1 && osc3_m_eff == 8'd0) || (osc3_n_eff == 8'd0 && osc3_m_eff == 8'd1));

// ---- 三路振荡器输入源选择 + 打一拍再进 PSD (打断 ADC→混频长路径, 修时序) ------
reg signed [13:0] adc_ch3_r, adc_ch4_r;
always @(posedge clk_65M) begin
    adc_ch3_r <= adc_ch3;
    adc_ch4_r <= adc_ch4;
end

wire signed [14:0] diff_ch34 = $signed(adc_ch3_r) - $signed(adc_ch4_r);
wire signed [13:0] diff_ch34_sat = (diff_ch34 >  15'sd8191) ?  14'sd8191 :
                                   (diff_ch34 < -15'sd8192) ? -14'sd8192 :
                                                               diff_ch34[13:0];

wire signed [13:0] psd_in_osc1_c = (osc1_src_uart == 2'd0) ? adc_ch3_r :
                                   (osc1_src_uart == 2'd1) ? adc_ch4_r :
                                                              diff_ch34_sat;
wire signed [13:0] psd_in_osc2_c = (osc2_src_uart == 2'd0) ? adc_ch3_r :
                                   (osc2_src_uart == 2'd1) ? adc_ch4_r :
                                                              diff_ch34_sat;
wire signed [13:0] psd_in_osc3_c = (osc3_src_uart == 2'd0) ? adc_ch3_r :
                                   (osc3_src_uart == 2'd1) ? adc_ch4_r :
                                                              diff_ch34_sat;

reg signed [13:0] psd_in_osc1, psd_in_osc2, psd_in_osc3;
always @(posedge clk_65M) begin
    psd_in_osc1 <= psd_in_osc1_c;
    psd_in_osc2 <= psd_in_osc2_c;
    psd_in_osc3 <= psd_in_osc3_c;
end

// ---- 振荡器 1 (默认 2F1+F2) ---------------------------------------------
wire signed [27:0] dc_x_ch3_21, dc_y_ch3_21;
wire               dc_valid_x_ch3_21, dc_valid_y_ch3_21;

lockin_psd #(.IN_WIDTH(28)) u_psd_ch3_21 (
    .clk         (clk_65M),
    .rst_n       (sys_rst_n),
    .adc_in      (psd_in_osc1),
    .ref_freq    (ref_freq_21_to_psd),
    .ref_phase   (48'd0),
    .use_coh_ref (ref_freq_auto_uart),
    .coh_ref_pll_direct(coh1_pll_direct),
    .coh_ref_sine(coh1_sin),
    .coh_ref_cos (coh1_cos),
    .tau         (tau21_uart),
    .iir_order   (order21_uart),
    .dc_x        (dc_x_ch3_21),
    .dc_y        (dc_y_ch3_21),
    .cic_valid_x (),
    .cic_valid_y (),
    .dc_valid_x  (dc_valid_x_ch3_21),
    .dc_valid_y  (dc_valid_y_ch3_21),
    .ref_sine_o  (osc1_ref_sine)
);

// ---- 振荡器 2 (默认 F1+2F2) ---------------------------------------------
wire signed [27:0] dc_x_ch3_12, dc_y_ch3_12;
wire               dc_valid_x_ch3_12, dc_valid_y_ch3_12;

lockin_psd #(.IN_WIDTH(28)) u_psd_ch3_12 (
    .clk         (clk_65M),
    .rst_n       (sys_rst_n),
    .adc_in      (psd_in_osc2),
    .ref_freq    (ref_freq_12_to_psd),
    .ref_phase   (48'd0),
    .use_coh_ref (ref_freq_auto_uart),
    .coh_ref_pll_direct(coh2_pll_direct),
    .coh_ref_sine(coh2_sin),
    .coh_ref_cos (coh2_cos),
    .tau         (tau12_uart),
    .iir_order   (order12_uart),
    .dc_x        (dc_x_ch3_12),
    .dc_y        (dc_y_ch3_12),
    .cic_valid_x (),
    .cic_valid_y (),
    .dc_valid_x  (dc_valid_x_ch3_12),
    .dc_valid_y  (dc_valid_y_ch3_12),
    .ref_sine_o  (osc2_ref_sine)
);

// ---- 振荡器 3 (默认 F1+F2) ----------------------------------------------
wire signed [27:0] dc_x_ch3_11, dc_y_ch3_11;
wire               dc_valid_x_ch3_11, dc_valid_y_ch3_11;

lockin_psd #(.IN_WIDTH(28)) u_psd_ch3_11 (
    .clk         (clk_65M),
    .rst_n       (sys_rst_n),
    .adc_in      (psd_in_osc3),
    .ref_freq    (ref_freq_11_to_psd),
    .ref_phase   (48'd0),
    .use_coh_ref (ref_freq_auto_uart),
    .coh_ref_pll_direct(coh3_pll_direct),
    .coh_ref_sine(coh3_sin),
    .coh_ref_cos (coh3_cos),
    .tau         (tau11_uart),
    .iir_order   (order11_uart),
    .dc_x        (dc_x_ch3_11),
    .dc_y        (dc_y_ch3_11),
    .cic_valid_x (),
    .cic_valid_y (),
    .dc_valid_x  (dc_valid_x_ch3_11),
    .dc_valid_y  (dc_valid_y_ch3_11),
    .ref_sine_o  (osc3_ref_sine)
);

// ---- 通道3 DC 通路: 直接 CIC + IIR (无混频) ------------------------------
wire signed [27:0] adc_ch3_ext = {{14{adc_ch3[13]}}, adc_ch3};
wire signed [27:0] cic_dc_ch3;
wire               cic_valid_dc_ch3;
cic_compiler_0 u_cic_dc_ch3 (
    .aclk                (clk_65M),
    .s_axis_data_tdata   (adc_ch3_ext), .s_axis_data_tvalid (1'b1), .s_axis_data_tready (),
    .m_axis_data_tdata   (cic_dc_ch3),  .m_axis_data_tvalid (cic_valid_dc_ch3)
);

wire signed [27:0] dc_ch3;
wire               dc_valid_ch3;
iir_lpf_cascade #(.IN_WIDTH(28), .FRAC_WIDTH(32)) u_iir_dc_ch3 (
    .clk(clk_65M), .rst_n(sys_rst_n), .en(cic_valid_dc_ch3),
    .shift_k(tau_dc_uart), .order(order_dc_uart),
    .din(cic_dc_ch3), .dout(dc_ch3), .valid_out(dc_valid_ch3)
);


// =========================================================================
// ★ FT245BL 物理层 + 上层指令收发
// =========================================================================
wire [7:0] rec_data;
wire       rec_done;
wire       tx_done;
wire       send_en;
wire [7:0] send_data;

wire [7:0] ft_d_tx;
wire       ft_d_oe;
wire [7:0] ft_d_in;

assign ft_d    = ft_d_oe ? ft_d_tx : 8'bz;
assign ft_d_in = ft_d;

ft245_rx #(
    .CLK_PERIOD_NS(20),
    .T_RD_LOW_NS  (80),
    .T_RD_HIGH_NS (100)
) u_ft245_rx (
    .clk      (sys_clk ),
    .rst_n    (sys_rst_n),
    .ft_rxf_n (ft_rxf_n),
    .ft_rd_n  (ft_rd_n ),
    .ft_d_in  (ft_d_in ),
    .rec_data (rec_data),
    .rec_done (rec_done)
);

ft245_tx #(
    .CLK_PERIOD_NS(20),
    .T_WR_HIGH_NS (80),
    .T_WR_COOL_NS (160)
) u_ft245_tx (
    .clk      (sys_clk ),
    .rst_n    (sys_rst_n),
    .ft_txe_n (ft_txe_n),
    .ft_wr    (ft_wr   ),
    .ft_d_out (ft_d_tx ),
    .ft_d_oe  (ft_d_oe ),
    .send_en  (send_en ),
    .send_data(send_data),
    .tx_done  (tx_done )
);


// =========================================================================
// ★ 上位机回传帧打包 (80 字节 / 640 bit, 大端)
//   偏移        字段              类型           说明
//   --------- ----------------- ------------- ----------------------------
//   [ 0.. 3]  0xA5_5A_A5_5A    sync header   魔数, 用于对齐
//   [ 4.. 7]  dc_x_ch1          int32         通道1 @ F1 X (PLL 锁相输出)
//   [ 8..11]  dc_y_ch1          int32         通道1 @ F1 Y
//   [12..15]  dc_x_ch2          int32         通道2 @ F2 X
//   [16..19]  dc_y_ch2          int32         通道2 @ F2 Y
//   [20..23]  dc_x_ch3_21       int32         通道3 @ 2F1+F2 X
//   [24..27]  dc_y_ch3_21       int32         通道3 @ 2F1+F2 Y
//   [28..31]  dc_x_ch3_12       int32         通道3 @ F1+2F2 X
//   [32..35]  dc_y_ch3_12       int32         通道3 @ F1+2F2 Y
//   [36..39]  dc_x_ch3_11       int32         通道3 @ F1+F2  X
//   [40..43]  dc_y_ch3_11       int32         通道3 @ F1+F2  Y
//   [44..47]  dc_ch3            int32         通道3 DC 直流
//   [48..51]  adc_ch1           int32         ★ NEW: 通道1 原始 ADC 采样
//   [52..55]  adc_ch2           int32         ★ NEW: 通道2 原始 ADC 采样
//   [56..59]  adc_ch3           int32         ★ NEW: 通道3 原始 ADC 采样
//   [60..67]  pll_freq_ch1      uint64        ★ NEW: 通道1 锁定频率字 (48bit, 高 16bit 补0)
//   [68..75]  pll_freq_ch2      uint64        ★ NEW: 通道2 锁定频率字
//   [76..79]  lock_flags        int32         ★ NEW: bit0=ch1 locked, bit1=ch2 locked
// =========================================================================
// 28bit -> 32bit 符号扩展 (锁相 X/Y)
wire [31:0] s32_x_ch1    = {{4{dc_x_ch1   [27]}}, dc_x_ch1    };
wire [31:0] s32_y_ch1    = {{4{dc_y_ch1   [27]}}, dc_y_ch1    };
wire [31:0] s32_x_ch2    = {{4{dc_x_ch2   [27]}}, dc_x_ch2    };
wire [31:0] s32_y_ch2    = {{4{dc_y_ch2   [27]}}, dc_y_ch2    };
wire [31:0] s32_x_ch3_21 = {{4{dc_x_ch3_21[27]}}, dc_x_ch3_21 };
wire [31:0] s32_y_ch3_21 = {{4{dc_y_ch3_21[27]}}, dc_y_ch3_21 };
wire [31:0] s32_x_ch3_12 = {{4{dc_x_ch3_12[27]}}, dc_x_ch3_12 };
wire [31:0] s32_y_ch3_12 = {{4{dc_y_ch3_12[27]}}, dc_y_ch3_12 };
wire [31:0] s32_x_ch3_11 = {{4{dc_x_ch3_11[27]}}, dc_x_ch3_11 };
wire [31:0] s32_y_ch3_11 = {{4{dc_y_ch3_11[27]}}, dc_y_ch3_11 };
wire [31:0] s32_dc_ch3   = {{4{dc_ch3     [27]}}, dc_ch3      };

// 14bit -> 32bit 符号扩展 (原始 ADC)
wire [31:0] s32_adc_ch1  = {{18{adc_ch1[13]}}, adc_ch1};
wire [31:0] s32_adc_ch2  = {{18{adc_ch2[13]}}, adc_ch2};
wire [31:0] s32_adc_ch3  = {{18{adc_ch3[13]}}, adc_ch3};

// 48bit -> 64bit 高位补 0 (PLL 锁定频率字)
wire [63:0] u64_pll_ch1  = {16'd0, pll_freq_ch1};
wire [63:0] u64_pll_ch2  = {16'd0, pll_freq_ch2};

// 锁定标志位 (位 0 = ch1 锁定, 位 1 = ch2 锁定)
wire [31:0] s32_lock     = {30'd0, is_locked_ch2, is_locked_ch1};

// ★ 诊断回读: 三路 PSD 实际生效的参考频率字 (48bit → 64bit 高位补 0)
//   用于核对硬件到底收到了什么频率 (自动=f_osc*_auto, 手动=freq_word_*).
wire [63:0] u64_ref_21 = {16'd0, ref_freq_21_to_psd};
wire [63:0] u64_ref_12 = {16'd0, ref_freq_12_to_psd};
wire [63:0] u64_ref_11 = {16'd0, ref_freq_11_to_psd};

wire [831:0] x_y_fir_packed = {
    32'hA5_5A_A5_5A,                            // sync
    s32_x_ch1,    s32_y_ch1,
    s32_x_ch2,    s32_y_ch2,
    s32_x_ch3_21, s32_y_ch3_21,
    s32_x_ch3_12, s32_y_ch3_12,
    s32_x_ch3_11, s32_y_ch3_11,
    s32_dc_ch3,
    s32_adc_ch1, s32_adc_ch2, s32_adc_ch3,      // 原始 ADC
    u64_pll_ch1,
    u64_pll_ch2,
    s32_lock,
    u64_ref_21, u64_ref_12, u64_ref_11          // ★ NEW 诊断: 三路实际参考频率字
};

usb_commend u_usb_commend (
    .clk(sys_clk),
    .rst_n(sys_rst_n),
    .rec_data(rec_data),
    .rec_done(rec_done),
    .tx_done(tx_done),
    .x_y_fir(x_y_fir_packed),
    // 数据帧触发: 用 PLL ch1 的 dc_valid_x 一拍 → 每帧上传一次
    .m_axis_data_tvalid_fir_x(dc_valid_x_ch1),
    // ★ 全部配置输出走 _w 原始信号, 经上方 CDC 块两拍同步到 clk_65M 域
    .center_freq(center_freq_uart),
    .pll_kp(pll_kp_w),
    .pll_ki(pll_ki_w),
    .tau1_x(tau1_x_w),
    .tau1_y(tau1_y_w),
    .tau2_x(tau2_x_w),
    .tau2_y(tau2_y_w),
    // ★ 通道3 三路谐波 IIR 时间常数 (X/Y 共用, 商用做法)
    .tau21(tau21_w),
    .tau12(tau12_w),
    .tau11(tau11_w),
    .tau_dc(tau_dc_w),
    .phase_offset(tx1_phase_word),
    .freq_word_2(tx1_freq_word_w),
    .freq_word_3(tx2_freq_word_w),
    // ★ 通道3 三路 ref_freq (FRQ21 / FRQ12 / FRQ11)
    .freq_word_21(freq_word_21_w),
    .freq_word_12(freq_word_12_w),
    .freq_word_11(freq_word_11_w),
    .sweep_thres(sweep_thres_w),     // ★ LOCKSWY 命令下发的值
    .lock_x_thres(lock_x_thres_w),   // ★ LOCKTHX 命令下发的值
    // ★ 通道3 ref_freq 来源 + 振荡器谐波系数
    .ref_freq_auto(ref_freq_auto_w),
    .osc1_n (osc1_n_w), .osc1_m (osc1_m_w),
    .osc2_n (osc2_n_w), .osc2_m (osc2_m_w),
    .osc3_n (osc3_n_w), .osc3_m (osc3_m_w),
    // ★ 三路振荡器输入源 (OSRC1/2/3: 0=CH3,1=CH4,2=CH3-CH4)
    .osc1_src(osc1_src_w), .osc2_src(osc2_src_w), .osc3_src(osc3_src_w),
    // ★ 通道3 4 路 IIR 阶数 (ORD21/ORD12/ORD11/ORDDC 命令各自独立: 1..4)
    .order21 (order21_w),
    .order12 (order12_w),
    .order11 (order11_w),
    .order_dc(order_dc_w),
    // ★ 信号发生器 (DAC904) 控制 (DMOD/DFRQ/DPHS)
    .dac_src_mode  (dac_src_mode_uart),
    .dac_freq_word (dac_freq_word_uart),
    .dac_phase_word(dac_phase_word_uart),
    .dac_amp       (dac_amp_uart),
    .dac_offset    (dac_offset_uart),
    .send_en(send_en),
    .send_data(send_data)
);


// =========================================================================
// ★ ILA 探针观察 (已注释: 释放布线拥塞, 减小 65M 域时序压力; 需调试再放开)
// =========================================================================
// ila_0 u_ila_0 (
//     .clk     (sys_clk),
//     .probe0  (adc_ch1),                 // 14bit
//     .probe1  (adc_ch2),                 // 14bit
//     .probe2  (adc_ch3),                 // 14bit
//     // PSD 已禁用, 把 probe3~6 切到 PLL 闭环量, 便于在 ILA 里直接看锁相过程
//     //   probe3/4 = ch1 X/Y (X≈幅度, Y≈相位误差→PI 输入)
//     //   probe5/6 = ch2 X/Y
//     // .probe3  (dc_x_ch1),                // 28bit
//     // .probe4  (dc_y_ch1),                // 28bit
//     // .probe5  (dc_x_ch2),                // 28bit
//     // .probe6  (dc_y_ch2)                 // 28bit
//     .probe3  (da_data)                // 14bit
// );


// =========================================================================
// ★ 以太网 UDP 上行 (PL 端千兆, 替代 / 并行于 FT245)
//    - 触发条件: 通道1 锁相 X 路 valid 一拍, 即每帧上传一次
//    - 数据载荷: 现成的 80 字节 x_y_fir_packed (含 0xA55AA55A sync header)
//    - 默认网络配置: FPGA=192.168.1.10, 上位机=192.168.1.100, UDP 端口 7777
//    - 修改 IP/MAC/端口请改下面的 parameter 覆盖值
// =========================================================================
// wire eth_link_up;
// wire [1:0] eth_link_speed;
// wire eth_frame_dropped;
// wire eth_rx_err_fcs;
// wire eth_rx_err_frame;
// wire eth_rx_activity;
// wire eth_rxctl_pin_active;
// wire eth_rxd_all_active;
// wire [3:0] eth_rxd_per_bit;
// wire eth_idelay_locked;
// wire eth_idelay_failed;
// wire [4:0] eth_idelay_tap_now;
// wire eth_rx_eth_hdr_activity;
// wire eth_tx_axis_activity;

// eth_lockin_top #(
//     .LOCAL_MAC      (48'h02_00_00_00_00_01),
//     // ★ 注意: 故意用 192.168.99.x 而不是 1.x, 避免和路由器/Wi-Fi 子网冲突
//     //   PC 上"以太网 5"网卡需手动配 IP=192.168.99.100, 掩码=255.255.255.0
//     .LOCAL_IP       ({8'd192, 8'd168, 8'd99, 8'd10}),
//     .DEST_IP        ({8'd192, 8'd168, 8'd99, 8'd100}),
//     .GATEWAY_IP     ({8'd192, 8'd168, 8'd99, 8'd1}),
//     .SUBNET_MASK    ({8'd255, 8'd255, 8'd255, 8'd0}),
//     .SRC_PORT       (16'd1234),
//     .DEST_PORT      (16'd7777),
//     .FRAME_BYTES    (80),
//     .RX_IDELAY_AUTO (1),    // ★ 1 = 自动扫描 0..31 找到能收帧的 tap
//     .RX_IDELAY_TAP  (24)
// ) u_eth_top (
//     .pl_clk_50m         (sys_clk),
//     .sys_rst            (sys_rst),

//     // 锁相数据 (65 MHz 域)
//     .lockin_clk         (clk_65M),
//     .lockin_frame_data  (x_y_fir_packed),
//     .lockin_frame_valid (dc_valid_x_ch1),

//     // RGMII PHY 引脚
//     .eth_rxc            (eth_rxc),
//     .eth_rxctl          (eth_rxctl),
//     .eth_rxd            (eth_rxd),
//     .eth_txc            (eth_txc),
//     .eth_txctl          (eth_txctl),
//     .eth_txd            (eth_txd),
//     .eth_nrst           (eth_nrst),
//     .eth_mdc            (eth_mdc),
//     .eth_mdio           (eth_mdio),

//     // 状态
//     .link_up            (eth_link_up),
//     .link_speed         (eth_link_speed),
//     .frame_dropped      (eth_frame_dropped),
//     .rx_error_bad_fcs   (eth_rx_err_fcs),
//     .rx_error_bad_frame (eth_rx_err_frame),
//     .rx_frame_activity  (eth_rx_activity),
//     .rxctl_pin_activity (eth_rxctl_pin_active),
//     .rxd_all_active     (eth_rxd_all_active),
//     .rxd_per_bit_active (eth_rxd_per_bit),
//     .idelay_scan_locked (eth_idelay_locked),
//     .idelay_scan_failed (eth_idelay_failed),
//     .idelay_scan_tap_now(eth_idelay_tap_now),
//     .rx_eth_hdr_activity(eth_rx_eth_hdr_activity),
//     .tx_axis_activity   (eth_tx_axis_activity)
// );

// // =========================================================================
// // LED 状态指示  (★ IDELAY + RX/TX 协议层活动 双重诊断 ★)
// //
// //   IDELAY 没锁定时 (上电几秒内):
// //     pl_led1 = 灭        (扫描进行中)
// //     pl_led2 = 灭 / 亮   (扫描失败时亮)
// //
// //   IDELAY 锁定后 (LED1 由灭转闪烁/亮):
// //     pl_led1 = RX 协议层活动 (eth_axis_rx 解析出帧)
// //        - 闪 = MAC RX → eth_axis_rx → udp_complete 链路通
// //        - 灭 = MAC 报 good_frame, 但 eth_axis_rx 没解出来 (反压?)
// //     pl_led2 = TX 协议层活动 (FPGA 在发任何帧)
// //        - 闪 = FPGA 在产生 TX (ARP 响应/UDP 数据), 物理 TX 出问题就看这
// //        - 灭 = FPGA 完全没产生 TX (ARP 模块没识别请求 / RX 内容不对)
// //
// //   组合判读 (锁定后):
// //     LED1 闪 + LED2 闪 → 协议层都 OK, 问题在 PHY 物理 TX 层
// //     LED1 闪 + LED2 灭 → ARP 没响应, 检查 LOCAL_IP 或 ARP 模块
// //     LED1 灭 + LED2 灭 → eth_axis_rx 没消费, RX backpress 问题
// // =========================================================================
// assign pl_led1 = eth_idelay_locked ? eth_rx_eth_hdr_activity : 1'b0;
// assign pl_led2 = eth_idelay_locked ? eth_tx_axis_activity    : eth_idelay_failed;

// eth_lockin_top 未例化时: 输出端口仍需驱动, 并避免 eth_pins.xdc 产生无效时序路径
assign eth_txc   = 1'b0;
assign eth_txctl = 1'b0;
assign eth_txd   = 4'b0;
assign eth_nrst  = 1'b1;   // PHY 释放复位 (无 MAC 时保持空闲)
assign eth_mdc   = 1'b0;
assign eth_mdio  = 1'bz;
assign pl_led1   = 1'b0;
assign pl_led2   = 1'b0;

endmodule
