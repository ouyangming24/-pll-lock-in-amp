`timescale 1ns / 1ps
// =============================================================================
//  harm_sin_cos_n.v
//  由 sin(θ), cos(θ) 递推 sin(n·θ), cos(n·θ), n = 0..MAX_N (组合逻辑 + 输出寄存)
// =============================================================================
module harm_sin_cos_n #(
    parameter MAX_N = 8
)(
    input  wire               clk,
    input  wire signed [13:0] sin_a,
    input  wire signed [13:0] cos_a,
    input  wire [7:0]         n_in,
    output reg  signed [13:0] sin_na,
    output reg  signed [13:0] cos_na
);

    function signed [13:0] sat14;
        input signed [27:0] v;
        begin
            if (v > 28'sd8191)
                sat14 = 14'sd8191;
            else if (v < -28'sd8192)
                sat14 = -14'sd8192;
            else
                sat14 = v[13:0];
        end
    endfunction

    wire signed [13:0] s [0:MAX_N];
    wire signed [13:0] c [0:MAX_N];

    assign s[0] = 14'sd0;
    assign c[0] = 14'sd8191;
    assign s[1] = sin_a;
    assign c[1] = cos_a;

    genvar k;
    generate
        for (k = 2; k <= MAX_N; k = k + 1) begin : gen_harm
            wire signed [27:0] sp = s[k-1] * c[1] + c[k-1] * s[1];
            wire signed [27:0] cm = c[k-1] * c[1] - s[k-1] * s[1];
            assign s[k] = sat14(sp >>> 13);
            assign c[k] = sat14(cm >>> 13);
        end
    endgenerate

  wire [7:0] n_eff = (n_in > MAX_N) ? MAX_N[7:0] : n_in;

    wire signed [13:0] sin_sel = (n_eff == 8'd0) ? s[0] :
                                 (n_eff == 8'd1) ? s[1] :
                                 (n_eff == 8'd2) ? s[2] :
                                 (n_eff == 8'd3) ? s[3] :
                                 (n_eff == 8'd4) ? s[4] :
                                 (n_eff == 8'd5) ? s[5] :
                                 (n_eff == 8'd6) ? s[6] :
                                 (n_eff == 8'd7) ? s[7] : s[8];

    wire signed [13:0] cos_sel = (n_eff == 8'd0) ? c[0] :
                                 (n_eff == 8'd1) ? c[1] :
                                 (n_eff == 8'd2) ? c[2] :
                                 (n_eff == 8'd3) ? c[3] :
                                 (n_eff == 8'd4) ? c[4] :
                                 (n_eff == 8'd5) ? c[5] :
                                 (n_eff == 8'd6) ? c[6] :
                                 (n_eff == 8'd7) ? c[7] : c[8];

    always @(posedge clk) begin
        sin_na <= sin_sel;
        cos_na <= cos_sel;
    end

endmodule
