`timescale 1ns / 1ps
// =============================================================================
//  lockin_psd.v
//
//  锁相放大器 (Phase-Sensitive Detector, PSD) ── 开环版本
//
//  功能:
//      给定一个 ADC 信号 + 一个外部指定的参考频率 ref_freq, 在该频点
//      做相敏检测, 输出 X/Y (同相/正交) 直流分量。
//      与 pll_loop.v 的区别: 不带 PI 反馈, 参考频率由外部直接给定。
//      适合:  - 多频点同时解调 (本工程通道3 在 2F1+F2、F1+2F2、F1+F2 上的应用)
//             - 已知激励频率, 不需要锁相跟踪的场景
//
//  数据通路:
//      adc_in ──┬─▶ × ref_sine ─▶ CIC ─▶ IIR_x ─▶ dc_x
//               │                                   ▲
//               └─▶ × ref_cos  ─▶ CIC ─▶ IIR_y ─▶ dc_y
//                              ▲
//                              │
//                       ┌─────────────┐
//                       │ dds_compiler│  ◀── ref_freq (外部直接给)
//                       │ (本振)       │
//                       └─────────────┘
//
//  外部依赖 IP/模块:
//      - dds_compiler_1   : 本振参考 DDS
//      - mult_hunpin      : 14×14 有符号乘法器
//      - cic_compiler_0   : CIC 降采样滤波
//      - iir_lpf_cascade  : 1~4 阶级联 IIR 指数平均低通 (运行时可选阶数)
// =============================================================================
module lockin_psd #(
    parameter IN_WIDTH = 28
)(
    input                                clk,
    input                                rst_n,

    // 输入信号 + 参考频率
    input  signed [13:0]                 adc_in,
    input  [47:0]                        ref_freq,    // 参考频率字 (直接喂给 DDS)
    input  [47:0]                        ref_phase,   // 参考相位 (默认接 48'd0 即可)
    // ★ X/Y 共用同一个 IIR 时间常数 (与 SR830 等商用锁相放大器一致)
    //   保证复数信号 X+jY 经过完全对称的滤波器, 避免引入伪相位偏差.
    input  [4:0]                         tau,         // X/Y 共用 IIR 平滑系数
    // ★ IIR 滤波器阶数 (1~4): 等效 6/12/18/24 dB/oct 阻带斜率, 模仿 SR830
    //   阶数越高 → 噪声抑制越强, 但建立时间也越长 (~N · tau)
    input  [2:0]                         iir_order,

    // 输出
    output signed [IN_WIDTH-1:0]         dc_x,
    output signed [IN_WIDTH-1:0]         dc_y,
    output                               cic_valid_x,
    output                               cic_valid_y,
    output                               dc_valid_x,
    output                               dc_valid_y
);

    // ========================================================================
    // 1) 本振参考 DDS (开环, 频率字直接由外部给)
    // ========================================================================
    wire [95:0] ref_dds_cfg = {ref_phase, ref_freq};

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
        .CLK (clk), .A (adc_in), .B (ref_sine), .P (mix_x)
    );

    mult_hunpin u_mix_y (
        .CLK (clk), .A (adc_in), .B (ref_cos),  .P (mix_y)
    );

    // ========================================================================
    // 3) CIC 降采样
    // ========================================================================
    wire signed [IN_WIDTH-1:0] cic_x;
    wire signed [IN_WIDTH-1:0] cic_y;

    cic_compiler_0 u_cic_x (
        .aclk                (clk),
        .s_axis_data_tdata   (mix_x), .s_axis_data_tvalid (1'b1), .s_axis_data_tready (),
        .m_axis_data_tdata   (cic_x), .m_axis_data_tvalid (cic_valid_x)
    );

    cic_compiler_0 u_cic_y (
        .aclk                (clk),
        .s_axis_data_tdata   (mix_y), .s_axis_data_tvalid (1'b1), .s_axis_data_tready (),
        .m_axis_data_tdata   (cic_y), .m_axis_data_tvalid (cic_valid_y)
    );

    // ========================================================================
    // 4) IIR 指数平均低通 (多阶级联, 阶数由 iir_order 运行时选择)
    // ========================================================================
    iir_lpf_cascade #(
        .IN_WIDTH   (IN_WIDTH),
        .FRAC_WIDTH (32)
    ) u_iir_x (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (cic_valid_x),
        .shift_k    (tau),
        .order      (iir_order),
        .din        (cic_x),
        .dout       (dc_x),
        .valid_out  (dc_valid_x)
    );

    iir_lpf_cascade #(
        .IN_WIDTH   (IN_WIDTH),
        .FRAC_WIDTH (32)
    ) u_iir_y (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (cic_valid_y),
        .shift_k    (tau),
        .order      (iir_order),
        .din        (cic_y),
        .dout       (dc_y),
        .valid_out  (dc_valid_y)
    );

endmodule
