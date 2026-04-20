`timescale 1ns / 1ps

module lock_in_amp(
    input                 sys_clk     ,  //系统时钟
    input                 sys_rst_n   ,  //系统复位，低电平有效
//    //DA芯片接口
//    output  wire          dac_pd      ,   // DAC掉电控制
//    output  wire          dac_clk     ,   // DAC时钟输出
//    output  wire  [13:0]  da_data     ,   // DAC数据输出

   //AD芯片接口
   input   wire  [13:0]  adc_data    ,   // ADC数据输入
   input   wire          adc_otr     ,   // ADC过量程指示
   output  wire          adc_pdn     ,   // ADC掉电控制
   output  wire          adc_oeb_b   ,   // ADC输出使能（低电平有效）
   output  wire          adc_clk     ,   // ADC采样时钟输出

    input  wire uart_rx,             // UART接收端口
    output wire uart_tx              // UART发送端口
);

//===========================================================================
// 命名约定：
//   - 两路AD采样锁定通道的所有信号均以 _ch1 / _ch2 结尾
//   - 角色前缀：adc_  (AD采样)   ref_  (本振参考DDS)    mix_  (混频乘法器)
//              cic_  (CIC滤波)   iir_  (IIR滤波)       dc_   (直流分量输出)
//              pll_  (PLL控制器)  fft_  (FFT寻峰)      center_freq_ (中心频率)
//   - 两个独立测试信号 DDS (由 UART FRQ2/FRQ3 指令控制) 以 _tx1 / _tx2 结尾
//   - 三个和差频 DDS 保持 _21 / _12 / _11 后缀
//===========================================================================

assign sys_rst = ~sys_rst_n;

// AD数据接收 ---------------------------------------------------------------
wire  [13:0]  adc_ch1;  // AD通道A采样数据 (锁定通道1输入)
wire  [13:0]  adc_ch2;  // AD通道B采样数据 (锁定通道2输入)

//*****************************************************
//**                    时钟网络
//*****************************************************
wire clk_65M;
wire clk_locked;

clk_wiz_0 u_clk_wiz_0 (
    .clk_out1 (clk_65M),     // 65MHz 主工作时钟
    .reset    (sys_rst),
    .locked   (clk_locked),
    .clk_in1  (sys_clk)
);


// =========================================================================
// ★ 数字锁相环 (PLL) 公共信号
// =========================================================================
wire pll_en = 1'b1; // 锁相环使能开关

// UART 参数控制信号
wire [47:0] center_freq_uart; // FREQ 指令 (本设计未直接使用，预留)
wire [15:0] pll_kp;
wire [15:0] pll_ki;
wire [4:0]  tau_x;
wire [4:0]  tau_y;


// =========================================================================
// ★ 通道1: FFT 自动寻峰及中心频率追踪 (32768 点)
// =========================================================================
wire                fft_tready_ch1;
wire                freq_updated_ch1;
wire signed [47:0]  center_freq_auto_ch1;

reg [15:0] fft_cnt_ch1 = 0;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        fft_cnt_ch1 <= 0;
    end else if (fft_tready_ch1) begin
        fft_cnt_ch1 <= fft_cnt_ch1 + 1'b1;
    end
end
wire fft_tlast_ch1 = (fft_cnt_ch1 == 16'd32767);

fft_peak_tracker u_fft_ch1 (
    .clk                (clk_65M),
    .rst_n              (sys_rst_n),

    .s_axis_data_tdata  ({16'd0, {2{adc_ch1[13]}}, adc_ch1}),
    .s_axis_data_tvalid (1'b1),
    .s_axis_data_tlast  (fft_tlast_ch1),
    .s_axis_data_tready (fft_tready_ch1),

    .center_freq        (center_freq_auto_ch1),
    .freq_update_valid  (freq_updated_ch1)
);

// =========================================================================
// ★ 通道2: FFT 自动寻峰及中心频率追踪 (32768 点)
// =========================================================================
wire                fft_tready_ch2;
wire                freq_updated_ch2;
wire signed [47:0]  center_freq_auto_ch2;

reg [15:0] fft_cnt_ch2 = 0;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        fft_cnt_ch2 <= 0;
    end else if (fft_tready_ch2) begin
        fft_cnt_ch2 <= fft_cnt_ch2 + 1'b1;
    end
end
wire fft_tlast_ch2 = (fft_cnt_ch2 == 16'd32767);

fft_peak_tracker u_fft_ch2 (
    .clk                (clk_65M),
    .rst_n              (sys_rst_n),

    .s_axis_data_tdata  ({16'd0, {2{adc_ch2[13]}}, adc_ch2}),
    .s_axis_data_tvalid (1'b1),
    .s_axis_data_tlast  (fft_tlast_ch2),
    .s_axis_data_tready (fft_tready_ch2),

    .center_freq        (center_freq_auto_ch2),
    .freq_update_valid  (freq_updated_ch2)
);


wire [47:0] tx1_phase_word;              // 串口输入控制相位 (PHAS 指令)
wire [47:0] tx1_freq_word;               // 串口输入控制频率 (FRQ2 指令)
wire [47:0] tx2_phase_word = 48'd0;              // 串口输入控制相位 (PHAS 指令)
wire [47:0] tx2_freq_word;               // 串口输入控制频率 (FRQ3 指令)

// =========================================================================
// ★ 通道1: PLL 控制器 (提前声明所需反馈信号)
// =========================================================================
wire [47:0]         pll_freq_ch1;       // PLL 输出频率控制字 -> 驱动本振DDS
wire signed [27:0]  dc_x_ch1;           // IIR 输出 X (同相幅值)
wire signed [27:0]  dc_y_ch1;           // IIR 输出 Y (正交/相位误差)
wire                dc_valid_x_ch1;
wire                dc_valid_y_ch1;
wire                cic_valid_x_ch1;
wire                cic_valid_y_ch1;
wire                is_locked_ch1;

pll_controller #(
    .KI_FRAC      ( 16      ),
    .IN_WIDTH     ( 28      ),
    .SWEEP_THRES  ( 28'd5000 ),        // 捕捉差频的阈值
    .LOCK_X_THRES ( 28'd8000 )         // 维持锁定的信号幅值阈值
) u_pll_ch1 (
    .clk            ( clk_65M              ),
    .rst_n          ( sys_rst_n            ),
    .pll_en         ( pll_en               ),
    .pll_kp         ( pll_kp               ),
    .pll_ki         ( pll_ki               ),
    .center_freq    ( center_freq_auto_ch1 ),
    .phase_error_in ( dc_y_ch1             ),
    .amp_in         ( dc_x_ch1             ),
    .valid_in       ( cic_valid_y_ch1      ),
    .dds_freq_out   ( pll_freq_ch1         ),
    .is_locked      ( is_locked_ch1        )
);

// =========================================================================
// ★ 通道2: PLL 控制器
// =========================================================================
wire [47:0]         pll_freq_ch2;
wire signed [27:0]  dc_x_ch2;
wire signed [27:0]  dc_y_ch2;
wire                dc_valid_x_ch2;
wire                dc_valid_y_ch2;
wire                cic_valid_x_ch2;
wire                cic_valid_y_ch2;
wire                is_locked_ch2;

pll_controller #(
    .KI_FRAC      ( 16      ),
    .IN_WIDTH     ( 28      ),
    .SWEEP_THRES  ( 28'd5000 ),
    .LOCK_X_THRES ( 28'd8000 )
) u_pll_ch2 (
    .clk            ( clk_65M              ),
    .rst_n          ( sys_rst_n            ),
    .pll_en         ( pll_en               ),
    .pll_kp         ( pll_kp               ),  // 共用一组 PI 参数
    .pll_ki         ( pll_ki               ),
    .center_freq    ( center_freq_auto_ch2 ),
    .phase_error_in ( dc_y_ch2             ),
    .amp_in         ( dc_x_ch2             ),
    .valid_in       ( cic_valid_y_ch2      ),
    .dds_freq_out   ( pll_freq_ch2         ),
    .is_locked      ( is_locked_ch2        )
);


// =========================================================================
// ★ 通道1: 本振参考 DDS (PLL 闭环内，用于混频解调)
// =========================================================================
wire [47:0] ref_phase_ch1 = 48'd0;
wire [95:0] dds_ref_ch1_config = {ref_phase_ch1, pll_freq_ch1};

wire signed [31:0] ref_sine_cos_ch1;
wire signed [13:0] ref_sine_ch1 = ref_sine_cos_ch1[29:16];
wire signed [13:0] ref_cos_ch1  = ref_sine_cos_ch1[13:0];

dds_compiler_1 u_dds_ref_ch1 (
  .aclk                  (clk_65M),
  .s_axis_config_tvalid  (1'b1),
  .s_axis_config_tdata   (dds_ref_ch1_config),
  .m_axis_data_tvalid    (),
  .m_axis_data_tdata     (ref_sine_cos_ch1),
  .m_axis_phase_tvalid   (),
  .m_axis_phase_tdata    ()
);

// =========================================================================
// ★ 通道2: 本振参考 DDS (PLL 闭环内，用于混频解调)
// =========================================================================
wire [47:0] ref_phase_ch2 = 48'd0;
wire [95:0] dds_ref_ch2_config = {ref_phase_ch2, pll_freq_ch2};

wire signed [31:0] ref_sine_cos_ch2;
wire signed [13:0] ref_sine_ch2 = ref_sine_cos_ch2[29:16];
wire signed [13:0] ref_cos_ch2  = ref_sine_cos_ch2[13:0];

dds_compiler_1 u_dds_ref_ch2 (
  .aclk                  (clk_65M),
  .s_axis_config_tvalid  (1'b1),
  .s_axis_config_tdata   (dds_ref_ch2_config),
  .m_axis_data_tvalid    (),
  .m_axis_data_tdata     (ref_sine_cos_ch2),
  .m_axis_phase_tvalid   (),
  .m_axis_phase_tdata    ()
);

// =========================================================================
// ★ AD / DA 接口
// =========================================================================
//wire [13:0] data_buf;
//sin_amp_offset u_sin_amp_offset(
//    .clk          (sys_clk),
//    .rst_n        (sys_rst_n),
//    .signed_in    (sine_tx1),    // 示例: 把 tx1 信号送 DAC
//    .scale_factor (31'd50),
//    .bias         (1'd0),
//    .unsigned_out (data_buf)
//);

//da_wave_send u_da_wave_send(
//    .CLK_165M  (sys_clk ),
//    .SYS_RST   (sys_rst_n),
//    .DATA_BUF  (data_buf ),
//    .PD        (dac_pd   ),
//    .DAC_CLK   (dac_clk  ),
//    .DAC_DATA  (da_data  )
//);

// AD 数据接收
ad_wave_rec u_ad_wave_rec(
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


// =========================================================================
// ★ 通道1: 混频 (乘法器)
// =========================================================================
wire signed [27:0] mix_x_ch1;
mult_hunpin u_mix_x_ch1 (
  .CLK (clk_65M),
  .A   (adc_ch1),
  .B   (ref_sine_ch1),
  .P   (mix_x_ch1)
);

wire signed [27:0] mix_y_ch1;
mult_hunpin u_mix_y_ch1 (
  .CLK (clk_65M),
  .A   (adc_ch1),
  .B   (ref_cos_ch1),
  .P   (mix_y_ch1)
);

// =========================================================================
// ★ 通道2: 混频 (乘法器)
// =========================================================================
wire signed [27:0] mix_x_ch2;
mult_hunpin u_mix_x_ch2 (
  .CLK (clk_65M),
  .A   (adc_ch2),
  .B   (ref_sine_ch2),
  .P   (mix_x_ch2)
);

wire signed [27:0] mix_y_ch2;
mult_hunpin u_mix_y_ch2 (
  .CLK (clk_65M),
  .A   (adc_ch2),
  .B   (ref_cos_ch2),
  .P   (mix_y_ch2)
);


// =========================================================================
// ★ 通道1: CIC 降采样滤波
// =========================================================================
wire signed [27:0] cic_x_ch1;
wire               cic_x_tready_ch1;
cic_compiler_0 u_cic_x_ch1 (
  .aclk                (clk_65M),
  .s_axis_data_tdata   (mix_x_ch1),
  .s_axis_data_tvalid  (1'b1),
  .s_axis_data_tready  (cic_x_tready_ch1),
  .m_axis_data_tdata   (cic_x_ch1),
  .m_axis_data_tvalid  (cic_valid_x_ch1)
);

wire signed [27:0] cic_y_ch1;
wire               cic_y_tready_ch1;
cic_compiler_0 u_cic_y_ch1 (
  .aclk                (clk_65M),
  .s_axis_data_tdata   (mix_y_ch1),
  .s_axis_data_tvalid  (1'b1),
  .s_axis_data_tready  (cic_y_tready_ch1),
  .m_axis_data_tdata   (cic_y_ch1),
  .m_axis_data_tvalid  (cic_valid_y_ch1)
);

// =========================================================================
// ★ 通道2: CIC 降采样滤波
// =========================================================================
wire signed [27:0] cic_x_ch2;
wire               cic_x_tready_ch2;
cic_compiler_0 u_cic_x_ch2 (
  .aclk                (clk_65M),
  .s_axis_data_tdata   (mix_x_ch2),
  .s_axis_data_tvalid  (1'b1),
  .s_axis_data_tready  (cic_x_tready_ch2),
  .m_axis_data_tdata   (cic_x_ch2),
  .m_axis_data_tvalid  (cic_valid_x_ch2)
);

wire signed [27:0] cic_y_ch2;
wire               cic_y_tready_ch2;
cic_compiler_0 u_cic_y_ch2 (
  .aclk                (clk_65M),
  .s_axis_data_tdata   (mix_y_ch2),
  .s_axis_data_tvalid  (1'b1),
  .s_axis_data_tready  (cic_y_tready_ch2),
  .m_axis_data_tdata   (cic_y_ch2),
  .m_axis_data_tvalid  (cic_valid_y_ch2)
);


// =========================================================================
// ★ 通道1: IIR 指数移动平均 (提取微弱直流分量)
// =========================================================================
iir_lpf_ema #(
    .IN_WIDTH   ( 28 ),
    .FRAC_WIDTH ( 32 )
) u_iir_x_ch1 (
    .clk        ( clk_65M          ),
    .rst_n      ( sys_rst_n        ),
    .en         ( cic_valid_x_ch1  ),
    .shift_k    ( tau_x            ), // X通道(测量幅值)保持慢速滤波
    .din        ( cic_x_ch1        ),
    .dout       ( dc_x_ch1         ),
    .valid_out  ( dc_valid_x_ch1   )
);

iir_lpf_ema #(
    .IN_WIDTH   ( 28 ),
    .FRAC_WIDTH ( 32 )
) u_iir_y_ch1 (
    .clk        ( clk_65M          ),
    .rst_n      ( sys_rst_n        ),
    .en         ( cic_valid_y_ch1  ),
    .shift_k    ( tau_y            ), // Y通道给PLL做反馈
    .din        ( cic_y_ch1        ),
    .dout       ( dc_y_ch1         ),
    .valid_out  ( dc_valid_y_ch1   )
);

// =========================================================================
// ★ 通道2: IIR 指数移动平均
// =========================================================================
iir_lpf_ema #(
    .IN_WIDTH   ( 28 ),
    .FRAC_WIDTH ( 32 )
) u_iir_x_ch2 (
    .clk        ( clk_65M          ),
    .rst_n      ( sys_rst_n        ),
    .en         ( cic_valid_x_ch2  ),
    .shift_k    ( tau_x            ),
    .din        ( cic_x_ch2        ),
    .dout       ( dc_x_ch2         ),
    .valid_out  ( dc_valid_x_ch2   )
);

iir_lpf_ema #(
    .IN_WIDTH   ( 28 ),
    .FRAC_WIDTH ( 32 )
) u_iir_y_ch2 (
    .clk        ( clk_65M          ),
    .rst_n      ( sys_rst_n        ),
    .en         ( cic_valid_y_ch2  ),
    .shift_k    ( tau_y            ),
    .din        ( cic_y_ch2        ),
    .dout       ( dc_y_ch2         ),
    .valid_out  ( dc_valid_y_ch2   )
);


// =========================================================================
// ★ 测试信号 DDS tx1 (由 UART 指令 FRQ2 控制频率, PHAS 控制相位)
// =========================================================================

wire [95:0] dds_tx1_config  = {48'd0, pll_freq_ch1};

wire signed [31:0] tx1_sine_cos;
wire signed [13:0] sine_tx1 = tx1_sine_cos[29:16];
wire signed [13:0] cos_tx1  = tx1_sine_cos[13:0];

dds_compiler_1 u_dds_tx1 (
  .aclk                  (clk_65M),
  .s_axis_config_tvalid  (1'b1),
  .s_axis_config_tdata   (dds_tx1_config),
  .m_axis_data_tvalid    (),
  .m_axis_data_tdata     (tx1_sine_cos),
  .m_axis_phase_tvalid   (),
  .m_axis_phase_tdata    ()
);

// =========================================================================
// ★ 测试信号 DDS tx2 (由 UART 指令 FRQ3 控制频率, 默认零相位)
// =========================================================================

wire [95:0] dds_tx2_config = {tx2_phase_word, pll_freq_ch2};

wire signed [31:0] tx2_sine_cos;
wire signed [13:0] sine_tx2 = tx2_sine_cos[29:16];
wire signed [13:0] cos_tx2  = tx2_sine_cos[13:0];

dds_compiler_1 u_dds_tx2 (
  .aclk                  (clk_65M),
  .s_axis_config_tvalid  (1'b1),
  .s_axis_config_tdata   (dds_tx2_config),
  .m_axis_data_tvalid    (),
  .m_axis_data_tdata     (tx2_sine_cos),
  .m_axis_phase_tvalid   (),
  .m_axis_phase_tdata    ()
);


// =========================================================================
// ★ 例化uart_commend模块 (UART 指令收发)
// =========================================================================
wire [7:0] rec_data;
wire rec_done;
wire tx_done;
wire send_en;
wire [7:0] send_data;

uart_rec u_uart_rec (
    .clk(sys_clk),
    .rst_n(sys_rst_n),
    .rx(uart_rx),
    .rec_data(rec_data),
    .rec_done(rec_done)
);

uart_send u_uart_send (
    .clk(sys_clk),
    .rst_n(sys_rst_n),
    .send_en(send_en),
    .send_data(send_data),
    .tx(uart_tx),
    .tx_done(tx_done)
);

// 打包通道1的 X/Y 滤波结果为 128 位 (上位机回传)
wire [127:0] x_y_fir_packed = {36'd0, dc_x_ch1, 36'd0, dc_y_ch1};

uart_commend u_uart_commend (
    .clk(sys_clk),
    .rst_n(sys_rst_n),
    .rec_data(rec_data),
    .rec_done(rec_done),
    .tx_done(tx_done),
    .x_y_fir(x_y_fir_packed),
    .m_axis_data_tvalid_fir_x(dc_valid_x_ch1),
    .center_freq(center_freq_uart),      // FREQ 指令输出 (未使用)
    .pll_kp(pll_kp),                     // KP 指令输出
    .pll_ki(pll_ki),                     // KI 指令输出
    .tau_x(tau_x),                       // TAUX 指令输出
    .tau_y(tau_y),                       // TAUY 指令输出
    .phase_offset(tx1_phase_word),       // PHAS 指令输出 -> tx1 相位
    .freq_word_2(tx1_freq_word),         // FRQ2 指令输出 -> tx1 频率
    .freq_word_3(tx2_freq_word),         // FRQ3 指令输出 -> tx2 频率
    .send_en(send_en),
    .send_data(send_data)
);


// =========================================================================
// ★ 和差频输出 DDS
// 注意: F1 = pll_freq_ch1, F2 当前仍绑定到 tx2_freq_word;
//       若要改用 pll_freq_ch2, 请将下面公式中的 tx2_freq_word 替换为 pll_freq_ch2
// =========================================================================

// --- 2F1 + F2 -----------------------------------------------------------
wire [47:0] dds_freq_21 = pll_freq_ch1 * 2 + tx2_freq_word;
wire [95:0] dds_cfg_21  = {48'd0, dds_freq_21};

wire signed [31:0] sine_cos_21;
wire signed [13:0] sine_21 = sine_cos_21[29:16];
wire signed [13:0] cos_21  = sine_cos_21[13:0];

dds_compiler_1 u_dds_21 (
  .aclk                  (clk_65M),
  .s_axis_config_tvalid  (1'b1),
  .s_axis_config_tdata   (dds_cfg_21),
  .m_axis_data_tvalid    (),
  .m_axis_data_tdata     (sine_cos_21),
  .m_axis_phase_tvalid   (),
  .m_axis_phase_tdata    ()
);

// --- F1 + 2F2 -----------------------------------------------------------
wire [47:0] dds_freq_12 = pll_freq_ch1 + 2 * tx2_freq_word;
wire [95:0] dds_cfg_12  = {48'd0, dds_freq_12};

wire signed [31:0] sine_cos_12;
wire signed [13:0] sine_12 = sine_cos_12[29:16];
wire signed [13:0] cos_12  = sine_cos_12[13:0];

dds_compiler_1 u_dds_12 (
  .aclk                  (clk_65M),
  .s_axis_config_tvalid  (1'b1),
  .s_axis_config_tdata   (dds_cfg_12),
  .m_axis_data_tvalid    (),
  .m_axis_data_tdata     (sine_cos_12),
  .m_axis_phase_tvalid   (),
  .m_axis_phase_tdata    ()
);

// --- F1 + F2 ------------------------------------------------------------
wire [47:0] dds_freq_11 = pll_freq_ch1 + tx2_freq_word;
wire [95:0] dds_cfg_11  = {48'd0, dds_freq_11};

wire signed [31:0] sine_cos_11;
wire signed [13:0] sine_11 = sine_cos_11[29:16];
wire signed [13:0] cos_11  = sine_cos_11[13:0];

dds_compiler_1 u_dds_11 (
  .aclk                  (clk_65M),
  .s_axis_config_tvalid  (1'b1),
  .s_axis_config_tdata   (dds_cfg_11),
  .m_axis_data_tvalid    (),
  .m_axis_data_tdata     (sine_cos_11),
  .m_axis_phase_tvalid   (),
  .m_axis_phase_tdata    ()
);



// =========================================================================
// ★ ILA 探针观察 (在 Vivado 中抓取波形)
// =========================================================================
ila_0 u_ila_0 (
    .clk     (sys_clk),
    .probe0  (ref_sine_ch1),            // 14bit: 通道1 本振参考正弦
    .probe1  (adc_ch1),                 // 14bit: 通道1 输入数据
    .probe2  (adc_ch2),                 // 14bit: 通道2 输入数据
    .probe3  (ref_cos_ch1),             // 14bit: 通道1 本振参考余弦
    .probe4  (cic_y_ch1),               // 28bit: 通道1 CIC Y
    .probe5  (pll_freq_ch1),            // 48bit: 通道1 PLL 锁定频率
    .probe6  (ref_sine_ch2),            // 14bit: 通道2 本振参考正弦
    .probe7  (ref_cos_ch2),             // 14bit: 通道2 本振参考余弦
    .probe8  (cic_y_ch2),               // 28bit: 通道2 CIC Y
    .probe9  (pll_freq_ch2),             // 48bit: 通道2 PLL 锁定频率
    .probe10 (center_freq_auto_ch1),
    .probe11 (center_freq_auto_ch2)
    
);

endmodule
