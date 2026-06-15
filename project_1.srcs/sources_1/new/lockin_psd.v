`timescale 1ns / 1ps
// =============================================================================
//  lockin_psd.v  —  开环 PSD
// =============================================================================
module lockin_psd #(
    parameter IN_WIDTH    = 28,
    parameter COH_ADC_DLY   = 3
)(
    input                                clk,
    input                                rst_n,

    input  signed [13:0]                 adc_in,
    input  [47:0]                        ref_freq,
    input  [47:0]                        ref_phase,
    input  wire                          use_coh_ref,
    input  wire                          coh_ref_pll_direct, // 1=参考直接来自 PLL 本振, 勿延迟 ADC
    input  wire signed [13:0]            coh_ref_sine,
    input  wire signed [13:0]            coh_ref_cos,
    input  [4:0]                         tau,
    input  [2:0]                         iir_order,

    output signed [IN_WIDTH-1:0]         dc_x,
    output signed [IN_WIDTH-1:0]         dc_y,
    output                               cic_valid_x,
    output                               cic_valid_y,
    output                               dc_valid_x,
    output                               dc_valid_y,
    output signed [13:0]                 ref_sine_o
);

    reg signed [13:0] adc_dly [0:COH_ADC_DLY-1];
    integer di;
    always @(posedge clk) begin
        adc_dly[0] <= adc_in;
        for (di = 1; di < COH_ADC_DLY; di = di + 1)
            adc_dly[di] <= adc_dly[di-1];
    end

    wire signed [13:0] adc_aligned = use_coh_ref ?
        (coh_ref_pll_direct ? adc_in : adc_dly[COH_ADC_DLY-1]) : adc_in;

    wire [95:0] ref_dds_cfg = {ref_phase, ref_freq};

    wire signed [31:0] ref_sine_cos;
    wire signed [13:0] ref_sine = ref_sine_cos[29:16];
    wire signed [13:0] ref_cos  = ref_sine_cos[13:0];

    wire signed [13:0] mix_ref_sine = use_coh_ref ? coh_ref_sine : ref_sine;
    wire signed [13:0] mix_ref_cos  = use_coh_ref ? coh_ref_cos  : ref_cos;

    assign ref_sine_o = mix_ref_sine;

    dds_compiler_1 u_dds_ref (
        .aclk                  (clk),
        .s_axis_config_tvalid  (!use_coh_ref),
        .s_axis_config_tdata   (ref_dds_cfg),
        .m_axis_data_tvalid    (),
        .m_axis_data_tdata     (ref_sine_cos),
        .m_axis_phase_tvalid   (),
        .m_axis_phase_tdata    ()
    );

    wire signed [IN_WIDTH-1:0] mix_x;
    wire signed [IN_WIDTH-1:0] mix_y;

    mult_hunpin u_mix_x (
        .CLK (clk), .A (adc_aligned), .B (mix_ref_sine), .P (mix_x)
    );

    mult_hunpin u_mix_y (
        .CLK (clk), .A (adc_aligned), .B (mix_ref_cos),  .P (mix_y)
    );

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
