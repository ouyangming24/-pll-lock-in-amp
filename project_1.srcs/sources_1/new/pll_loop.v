`timescale 1ns / 1ps
// =============================================================================
//  pll_loop.v
//
//  数字锁相环 (Phase-Locked Loop) ── 闭环版本
//
//  功能:
//      给定一个 ADC 信号, 自动跟踪其频率, 输出锁定后的 DDS 频率字。
//      内部同时做了相敏检测 (PSD), 副产物 dc_x/dc_y 可对外提供作为
//      "锁相幅值/相位误差" 使用。
//
//  数据通路:
//      adc_in ──┬─▶ × ref_sine ─▶ CIC ─▶ IIR_x ─▶ dc_x  (同相幅值)
//               │                                    │
//               └─▶ × ref_cos  ─▶ CIC ─▶ IIR_y ─▶ dc_y  (正交/相位误差)
//                              ▲                    │
//                              │                    ▼
//                       ┌─────────────┐    ┌─────────────────┐
//                       │ dds_compiler│◀───│ pll_controller  │
//                       │ (本振)       │    │ (PI + 扫频)     │
//                       └─────────────┘    └─────────────────┘
//                              ▲                    │
//                              └────────────────────┘
//                                  dds_freq_out
//
//  外部依赖 IP/模块:
//      - dds_compiler_1   : 本振参考 DDS (生成 sin/cos)
//      - mult_hunpin      : 14×14 有符号乘法器
//      - cic_compiler_0   : CIC 降采样滤波
//      - iir_lpf_ema      : IIR 指数平均低通
//      - pll_controller   : PI 控制器 + 扫频/锁定状态机
// =============================================================================
module pll_loop #(
    parameter        KI_FRAC      = 16,
    parameter        IN_WIDTH     = 28,
    parameter [27:0] SWEEP_THRES  = 28'd5000,
    parameter [27:0] LOCK_X_THRES = 28'd8000
)(
    input                                clk,         // 主工作时钟 (clk_65M)
    input                                rst_n,
    input                                pll_en,      // 锁相环使能

    // 待锁定的 ADC 输入信号
    input  signed [13:0]                 adc_in,

    // 上位机控制参数
    input  [47:0]                        center_freq, // PLL 扫频中心 / 起点频率
    input  [15:0]                        pll_kp,
    input  [15:0]                        pll_ki,
    input  [4:0]                         tau_x,       // X 路 IIR 平滑 (幅值)
    input  [4:0]                         tau_y,       // Y 路 IIR 平滑 (反馈)

    // 输出
    output [47:0]                        dds_freq_out,// 锁定的 DDS 频率字
    output signed [IN_WIDTH-1:0]         dc_x,        // 同相幅值
    output signed [IN_WIDTH-1:0]         dc_y,        // 正交/相位误差
    output                               cic_valid_x,
    output                               cic_valid_y,
    output                               dc_valid_x,
    output                               dc_valid_y,
    output                               is_locked
);

    // ========================================================================
    // 1) 本振参考 DDS (频率字由 PLL 反馈)
    // ========================================================================
    wire [95:0] ref_dds_cfg = {48'd0, dds_freq_out};

    wire signed [31:0] ref_sine_cos;
    wire signed [13:0] ref_sine = ref_sine_cos[29:16];
    wire signed [13:0] ref_cos  = ref_sine_cos[13:0];

    dds_compiler_1 u_dds_ref (
        .aclk                  (clk),
        .s_axis_config_tvalid  (1'b1),
        .s_axis_config_tdata   (ref_dds_cfg),
        .m_axis_data_tvalid    (),
        .m_axis_data_tdata     (ref_sine_cos),
        .m_axis_phase_tvalid   (),
        .m_axis_phase_tdata    ()
    );

    // ========================================================================
    // 2) 混频 (相敏检测)
    // ========================================================================
    wire signed [IN_WIDTH-1:0] mix_x;
    wire signed [IN_WIDTH-1:0] mix_y;

    mult_hunpin u_mix_x (
        .CLK (clk),
        .A   (adc_in),
        .B   (ref_sine),
        .P   (mix_x)
    );

    mult_hunpin u_mix_y (
        .CLK (clk),
        .A   (adc_in),
        .B   (ref_cos),
        .P   (mix_y)
    );

    // ========================================================================
    // 3) CIC 降采样
    // ========================================================================
    wire signed [IN_WIDTH-1:0] cic_x;
    wire signed [IN_WIDTH-1:0] cic_y;

    cic_compiler_0 u_cic_x (
        .aclk                (clk),
        .s_axis_data_tdata   (mix_x),
        .s_axis_data_tvalid  (1'b1),
        .s_axis_data_tready  (),
        .m_axis_data_tdata   (cic_x),
        .m_axis_data_tvalid  (cic_valid_x)
    );

    cic_compiler_0 u_cic_y (
        .aclk                (clk),
        .s_axis_data_tdata   (mix_y),
        .s_axis_data_tvalid  (1'b1),
        .s_axis_data_tready  (),
        .m_axis_data_tdata   (cic_y),
        .m_axis_data_tvalid  (cic_valid_y)
    );

    // ========================================================================
    // 4) IIR 指数平均低通 (幅值/相位平滑)
    // ========================================================================
    iir_lpf_ema #(
        .IN_WIDTH   (IN_WIDTH),
        .FRAC_WIDTH (32)
    ) u_iir_x (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (cic_valid_x),
        .shift_k    (tau_x),
        .din        (cic_x),
        .dout       (dc_x),
        .valid_out  (dc_valid_x)
    );

    iir_lpf_ema #(
        .IN_WIDTH   (IN_WIDTH),
        .FRAC_WIDTH (32)
    ) u_iir_y (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (cic_valid_y),
        .shift_k    (tau_y),
        .din        (cic_y),
        .dout       (dc_y),
        .valid_out  (dc_valid_y)
    );

    // ========================================================================
    // 5) PI 控制器 + 扫频/锁定状态机
    //    - dc_y 作为相位误差 (送 PI)
    //    - dc_x 作为锁定判据 (幅值阈值)
    //    - 输出 dds_freq_out 反馈给本振 DDS, 闭环
    // ========================================================================
    pll_controller #(
        .KI_FRAC      (KI_FRAC),
        .IN_WIDTH     (IN_WIDTH),
        .SWEEP_THRES  (SWEEP_THRES),
        .LOCK_X_THRES (LOCK_X_THRES)
    ) u_pll_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .pll_en         (pll_en),
        .pll_kp         (pll_kp),
        .pll_ki         (pll_ki),
        .center_freq    (center_freq),
        .phase_error_in (dc_y),
        .amp_in         (dc_x),
        .valid_in       (cic_valid_y),
        .dds_freq_out   (dds_freq_out),
        .is_locked      (is_locked)
    );

endmodule
