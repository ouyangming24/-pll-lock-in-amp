`timescale 1ns / 1ps

module lock_in_amp(
    input                 sys_clk     ,  //系统时钟
    input                 sys_rst_n   ,  //系统复位，低电平有效
//    //DA芯片接口
//    output  wire          dac_pd      ,   // DAC掉电控制
//    output  wire          dac_clk     ,   // DAC时钟输出
//    output  wire  [13:0]  da_data     ,   // DAC数据输出
    
//    //AD芯片接口
//    input   wire  [13:0]  adc_data    ,   // ADC数据输入
//    input   wire          adc_otr     ,   // ADC过量程指示
//    output  wire          adc_pdn     ,   // ADC掉电控制
//    output  wire          adc_oeb_b   ,   // ADC输出使能（低电平有效）
//    output  wire          adc_clk     ,   // ADC采样时钟输出
    
    input  wire uart_rx,             // UART接收端口
    output wire uart_tx              // UART发送端口
);

assign sys_rst = ~sys_rst_n;

//*****************************************************
//**                    时钟网络
//*****************************************************
wire clk_65M;
wire locked;

clk_wiz_0 u_clk_wiz_0 (
    .clk_out1 (clk_65M),     // 65MHz 主工作时钟
    .reset    (sys_rst), 
    .locked   (locked),       
    .clk_in1  (sys_clk)
);


// =========================================================================
// ★ DDS 1  用于输出外部信号
// =========================================================================
wire [47:0] phase_offset; //串口输入控制相位
wire [47:0] reg_phase_word_2 = phase_offset; 
wire [47:0] reg_freq_word_2;
wire [47:0] freq_word_2;  //串口输入控制频率
assign reg_freq_word_2 = freq_word_2;    
wire [95:0] dds_config_data_2 = {reg_phase_word_2,reg_freq_word_2}; 

wire signed [31:0] sine_cos_2;
wire signed [13:0] sine_2 = sine_cos_2[29:16]; // 这就是同频同相输出的信号
wire signed [13:0] cos_2  = sine_cos_2[13:0];

wire m_axis_data_tvalid_dds1;
wire m_axis_phase_tvalid_dds1;
wire [47:0] m_axis_phase_tdata_dds1;

// 例化第二个 DDS (请确保工程中 dds_compiler_1 支持多次例化)
dds_compiler_1 u_dds_compiler_1 (
  .aclk                  (clk_65M),                                  
  .s_axis_config_tvalid  (1'b1),  
  .s_axis_config_tdata   (dds_config_data_2),    
  .m_axis_data_tvalid    (m_axis_data_tvalid_dds1),      
  .m_axis_data_tdata     (sine_cos_2),        
  .m_axis_phase_tvalid   (m_axis_phase_tvalid_dds1),    
  .m_axis_phase_tdata    (m_axis_phase_tdata_dds1)      
);


// =========================================================================
// ★ 数字锁相环 (PLL) 逻辑
// =========================================================================
wire pll_en = 1'b1; // 锁相环使能开关

wire [47:0] reg_freq_word;   // 频率控制字 (PINC)，来自 PLL 动态计算
wire [47:0] reg_phase_word;  // 相位控制字 (POFF)

// UART 参数控制信号
wire [47:0] center_freq;
wire [15:0] pll_kp;
wire [15:0] pll_ki;
wire [4:0]  tau_x;
wire [4:0]  tau_y;


// IIR 滤波器的输出信号声明
wire signed [27:0] final_dc_out_x;
wire               final_dc_valid_x;
wire signed [27:0] final_dc_out_y;
wire               final_dc_valid_y;

wire               cic_valid_out_y;

// =========================================================================
// ★ FFT 自动寻峰及中心频率追踪 (65536 点)
// =========================================================================
wire fft_data_tready;

reg [15:0] fft_cnt = 0;
always @(posedge clk_65M or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        fft_cnt <= 0;
    end else if (fft_data_tready) begin
        fft_cnt <= fft_cnt + 1'b1;
    end
end
wire fft_tlast = (fft_cnt == 16'd65535);

wire freq_updated;
wire signed [47:0] auto_center_freq;

fft_peak_tracker u_fft_tracker (
    .clk                (clk_65M),
    .rst_n              (sys_rst_n),
    
    .s_axis_data_tdata  ({16'd0, {2{sine_2[13]}}, sine_2}),
    .s_axis_data_tvalid (1'b1),
    .s_axis_data_tlast  (fft_tlast), 
    .s_axis_data_tready (fft_data_tready),

    .center_freq        (auto_center_freq),
    .freq_update_valid  (freq_updated)
);

// 例化 PLL 控制器
wire is_locked; // 可以接一个 LED 灯观察是否锁定成功
pll_controller #(
    .KI_FRAC      ( 16     ),           
    .IN_WIDTH     ( 28      ),
    .SWEEP_THRES  ( 28'd5000  ),        // 捕捉差频的阈值，若一直不锁定可调小，若太灵敏导致假锁可调大
    .LOCK_X_THRES ( 28'd8000  )         // 维持锁定的信号幅值阈值
) u_pll_controller (
    .clk          ( clk_65M        ),
    .rst_n        ( sys_rst_n      ),
    .pll_en       ( pll_en         ),
    .pll_kp       ( pll_kp         ),
    .pll_ki       ( pll_ki         ),
    .center_freq  ( auto_center_freq ), // ★修改：使用FFT自动追踪的频率
    .phase_error_in ( final_dc_out_y ), 
    .amp_in       ( final_dc_out_x ),   // ★新增：X通道(同相幅值)作为锁定的最终裁判
    .valid_in     ( cic_valid_out_y ),  
    .dds_freq_out ( reg_freq_word  ),
    .is_locked    ( is_locked      )    // 锁定指示灯
);

// 相位偏置 
assign reg_phase_word = 48'd0; 

// =========================================================================
// ★ DDS 0: 用于混频和解调的本地参考信号 (闭环中)
// =========================================================================
wire [95:0] dds_config_data = {reg_phase_word, reg_freq_word}; 

wire signed [31:0] sine_cos;
wire signed [13:0] sine = sine_cos[29:16];
wire signed [13:0] cos  = sine_cos[13:0];

wire m_axis_data_tvalid_dds0;
wire m_axis_phase_tvalid_dds0;
wire [47:0] m_axis_phase_tdata_dds0;

dds_compiler_1 u_dds_compiler_0 (
  .aclk                  (clk_65M),                                  
  .s_axis_config_tvalid  (1'b1),  
  .s_axis_config_tdata   (dds_config_data),    
  .m_axis_data_tvalid    (m_axis_data_tvalid_dds0),      
  .m_axis_data_tdata     (sine_cos),        
  .m_axis_phase_tvalid   (m_axis_phase_tvalid_dds0),    
  .m_axis_phase_tdata    (m_axis_phase_tdata_dds0)      
);

// =========================================================================
// ★ AD / DA 接口
// =========================================================================
//wire [13:0] data_buf;
//sin_amp_offset u_sin_amp_offset(
//    .clk          (sys_clk),              
//    .rst_n        (sys_rst_n),          
//    .signed_in    (sine_2),     // 原始 DAC 输出依然绑定在闭环的 sine 上
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
//    .DAC_DATA  (da_data )   
//);

//// AD数据接收
//wire  [13:0]  adc_outa;
//wire  [13:0]  adc_outb;

//ad_wave_rec u_ad_wave_rec(
//    .CLK_65M   (clk_65M   ),  
//    .RST_N     (sys_rst_n ),  
//    .ADC_IN    (adc_data  ),  
//    .OTR       (adc_otr   ),  
//    .PDN       (adc_pdn   ),  
//    .OEB_B     (adc_oeb_b ),  
//    .ADC_CLK   (adc_clk   ),  
//    .ADC_OUTA  (adc_outa  ),  
//    .ADC_OUTB  (adc_outb  )   
//); 

// =========================================================================
// ★ 混频 (乘法器)
// =========================================================================
wire signed [27:0] ad_X; 
mult_hunpin x_mult_hunpin (
  .CLK (clk_65M),  
  .A   (sine_2),        
  .B   (sine),       
  .P   (ad_X)        
);

wire signed [27:0] ad_Y; 
mult_hunpin y_mult_hunpin (
  .CLK (clk_65M),  
  .A   (sine_2),        
  .B   (cos),        
  .P   (ad_Y)        
);

// =========================================================================
// ★ CIC 降采样滤波
// =========================================================================
wire signed [27:0] ad_X_cic;
wire               cic_valid_out_x;
wire               s_axis_data_tready_x;
cic_compiler_0 u_cic_compiler_x (
  .aclk                (clk_65M),
  .s_axis_data_tdata   (ad_X),              
  .s_axis_data_tvalid  (1'b1),
  .s_axis_data_tready  (s_axis_data_tready_x),
  .m_axis_data_tdata   (ad_X_cic),          
  .m_axis_data_tvalid  (cic_valid_out_x)
);

wire signed [27:0] ad_Y_cic;
//wire               cic_valid_out_y;
wire               s_axis_data_tready_y;
cic_compiler_0 u_cic_compiler_y (
  .aclk                (clk_65M),
  .s_axis_data_tdata   (ad_Y),              
  .s_axis_data_tvalid  (1'b1),
  .s_axis_data_tready  (s_axis_data_tready_y),
  .m_axis_data_tdata   (ad_Y_cic),          
  .m_axis_data_tvalid  (cic_valid_out_y)
);

// =========================================================================
// ★ IIR 指数移动平均滤波 (提取微弱直流分量)
// =========================================================================
iir_lpf_ema #(
    .IN_WIDTH   ( 28 ),    
    .FRAC_WIDTH ( 32 )     
) u_iir_lpf_ema_x (
    .clk        ( clk_65M ),
    .rst_n      ( sys_rst_n ),
    .en         ( cic_valid_out_x ),
    .shift_k    ( tau_x ), // X通道(测量幅值)保持慢速滤波，获得纯净直流
    .din        ( ad_X_cic ),
    .dout       ( final_dc_out_x ),
    .valid_out  ( final_dc_valid_x )
);

iir_lpf_ema #(
    .IN_WIDTH   ( 28 ),    
    .FRAC_WIDTH ( 32 )
) u_iir_lpf_ema_y (
    .clk        ( clk_65M ),
    .rst_n      ( sys_rst_n ),
    .en         ( cic_valid_out_y ),
    .shift_k    ( tau_y ), // Y通道给PLL做反馈，通过UART调节延迟
    .din        ( ad_Y_cic ),
    .dout       ( final_dc_out_y ),
    .valid_out  ( final_dc_valid_y )
);

// =========================================================================
// ★ 例化uart_commend模块
// =========================================================================

// 内部信号定义
wire [7:0] rec_data;              // 接收到的数据
wire rec_done;                    // 接收完成标志
wire tx_done;                     // 发送完成标志
wire send_en;                     // 发送使能
wire [7:0] send_data;             // 发送数据

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

// 打包 X 和 Y 数据为 128 位
wire [127:0] x_y_fir_packed = {36'd0, final_dc_out_x, 36'd0, final_dc_out_y};

uart_commend u_uart_commend (
    .clk(sys_clk),
    .rst_n(sys_rst_n),
    .rec_data(rec_data),
    .rec_done(rec_done),
    .tx_done(tx_done),
    .x_y_fir(x_y_fir_packed),                // 包含X和Y滤波后的数据
    .m_axis_data_tvalid_fir_x(final_dc_valid_x), // 数据有效标志
    .center_freq(center_freq),               // FREQ 指令输出
    .pll_kp(pll_kp),                         // KP 指令输出
    .pll_ki(pll_ki),                         // KI 指令输出
    .tau_x(tau_x),                           // TAUX 指令输出
    .tau_y(tau_y),                           // TAUY 指令输出
    .phase_offset(phase_offset),             // PHAS 指令输出
    .freq_word_2(freq_word_2),               // FRQ2 指令输出
    .send_en(send_en),                       // 发送使能
    .send_data(send_data)                    // 发送数据
);

// =========================================================================
// ★ ILA 探针观察 (在 Vivado 中抓取波形)
// =========================================================================
ila_0 u_ila_0 (
	.clk    (sys_clk),
	// probe0 原本是 14bit，现改为观察新 DDS 输出的【同频同相正弦波】
	.probe0 (sine),           // 14bit: 第二个DDS输出的同频同相正弦波 (与ADC做对比)
	.probe1 (ad_X),             // 28bit: 乘法器全精度输出
	.probe2 (ad_X_cic),         // 28bit: CIC降采样后输出（粗滤后）
	.probe3 (ad_Y),   // 28bit: IIR滤波后X通道纯净直流（同相分量，理想值等于信号幅值的一半）
	.probe4 (ad_Y_cic),   // 28bit: IIR滤波后Y通道纯净直流（正交分量，锁定时趋于0）
	.probe5 (reg_freq_word),             // 28bit: 乘法器全精度输出 Y通道
	.probe6 (cos),         // 28bit: CIC降采样后输出 Y通道
	.probe7 (sine_2),         // 28bit: CIC降采样后输出 Y通道
	.probe8 (cos_2),          // 14bit: ADC采集到的原始输入波形	
	.probe9 (is_locked),          // 14bit: 锁定状态指示灯
 	.probe10 (auto_center_freq),          // 48bit: 观察FFT找出的自动中心频率
    .probe11 (reg_freq_word_2)          // 32bit: DDS1输出
);

endmodule
