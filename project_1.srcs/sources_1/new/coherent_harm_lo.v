`timescale 1ns / 1ps
// =============================================================================
//  coherent_harm_lo.v
//
//  相位相干谐波本振: 由 CH1/CH2 PLL 本振相位实时组合
//
//    θ_harm = n·θ1 + m·θ2   (θ1/θ2 为 pll_loop 内 DDS 相位累加器输出)
//    输出 sin(θ_harm), cos(θ_harm)
//
//  与「独立 DDS + 仅借频率字」相比: 相位与 CH1/CH2 锁定本振严格相干,
//  上电/切模式后 Θ 读数稳定 (不再随机 0~360°).
//
//  实现: 每拍用 comb_phase 作 DDS 相位偏移, 频率字=0 (相位完全跟随 CH1/CH2).
// =============================================================================
module coherent_harm_lo (
    input  wire        clk,
    input  wire [47:0] phase_ch1,
    input  wire [47:0] phase_ch2,
    input  wire [7:0]  harm_n,
    input  wire [7:0]  harm_m,
    output wire signed [13:0] harm_sine,
    output wire signed [13:0] harm_cos
);

    wire [55:0] comb_phase_full = phase_ch1 * harm_n + phase_ch2 * harm_m;
    wire [47:0] comb_phase      = comb_phase_full[47:0];

    // {phase_offset, phase_increment}; increment=0 → 仅相位查找, 不独立积分
    wire [95:0] harm_dds_cfg = {comb_phase, 48'd0};

    wire signed [31:0] harm_sine_cos;

    dds_compiler_1 u_dds_harm (
        .aclk                  (clk),
        .s_axis_config_tvalid  (1'b1),
        .s_axis_config_tdata   (harm_dds_cfg),
        .m_axis_data_tvalid    (),
        .m_axis_data_tdata     (harm_sine_cos),
        .m_axis_phase_tvalid   (),
        .m_axis_phase_tdata    ()
    );

    assign harm_sine = harm_sine_cos[29:16];
    assign harm_cos  = harm_sine_cos[13:0];

endmodule
