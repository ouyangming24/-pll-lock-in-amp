`timescale 1ns / 1ps
// =============================================================================
//  coherent_harm_lo.v
//
//  sin(n·θ1 + m·θ2), cos(n·θ1 + m·θ2) 由 PLL 本振 sin/cos 合成 (与 CH1/CH2 混频参考一致).
//  sin(n·θ1+m·θ2) = sin(n·θ1)cos(m·θ2) + cos(n·θ1)sin(m·θ2)
// =============================================================================
module coherent_harm_lo (
    input  wire               clk,
    input  wire signed [13:0] sin1,
    input  wire signed [13:0] cos1,
    input  wire signed [13:0] sin2,
    input  wire signed [13:0] cos2,
    input  wire [7:0]         harm_n,
    input  wire [7:0]         harm_m,
    output reg signed [13:0]  harm_sine,
    output reg signed [13:0]  harm_cos
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

    reg [7:0] n_r, m_r;
    always @(posedge clk) begin
        n_r <= harm_n;
        m_r <= harm_m;
    end

    wire signed [13:0] sin_n, cos_n, sin_m, cos_m;

    harm_sin_cos_n #(.MAX_N(8)) u_hn (
        .clk(clk), .sin_a(sin1), .cos_a(cos1), .n_in(n_r),
        .sin_na(sin_n), .cos_na(cos_n)
    );

    harm_sin_cos_n #(.MAX_N(8)) u_hm (
        .clk(clk), .sin_a(sin2), .cos_a(cos2), .n_in(m_r),
        .sin_na(sin_m), .cos_na(cos_m)
    );

    wire signed [27:0] sp = sin_n * cos_m + cos_n * sin_m;
    wire signed [27:0] cp = cos_n * cos_m - sin_n * sin_m;

    reg signed [13:0] harm_sin_r, harm_cos_r;
    always @(posedge clk) begin
        harm_sin_r <= sat14(sp >>> 13);
        harm_cos_r <= sat14(cp >>> 13);
        harm_sine  <= harm_sin_r;
        harm_cos   <= harm_cos_r;
    end

endmodule
