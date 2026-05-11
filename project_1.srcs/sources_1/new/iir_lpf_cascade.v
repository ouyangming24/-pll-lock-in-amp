`timescale 1ns / 1ps
// =============================================================================
//  iir_lpf_cascade.v
//
//  多阶级联 IIR 指数平均低通  (1 ~ 4 阶 运行时可选)
//
//  设计动机:
//      原始 iir_lpf_ema 是 1 阶单极点 IIR (等价于 1 阶 RC, 6 dB/oct).
//      工业锁相放大器 (如 SR830/SR860) 提供 6/12/18/24 dB/oct 选项,
//      实现方式正是把若干个相同时间常数的一阶 RC "级联". 这样的好处:
//          - 时域响应单调收敛, 无过冲 (vs 巴特沃斯/切比雪夫有振铃)
//          - 实现简单, 资源极省 (复用现有 iir_lpf_ema, 仅加一个 mux)
//          - 时间常数 tau 含义不变, 用户只需额外选一个"阶数"
//
//  原理:
//      H(z) = [ alpha / (1 - (1-alpha) z^-1) ] ^ N      (N=order)
//      在 dB/oct 上每加一阶, 阻带斜率 + 6 dB/oct.
//      在 -3 dB 截止处, 总的相位偏移和带宽都会受 N 影响, 用户需要注意.
//
//  端口:
//      order   3 bit   1 ~ 4   选择 1 阶 / 2 阶 / 3 阶 / 4 阶输出
//                              其他值 (含 0) 一律视为 1 阶 (向后兼容)
//      shift_k 5 bit   所有级共用 (这是商用 LIA 的做法)
//
//  资源:
//      每级一个 iir_lpf_ema. 在 IN_WIDTH=28, FRAC_WIDTH=32 配置下,
//      单级约 200 LUT + 60 FF, 4 级总共 ~800 LUT + 240 FF.
// =============================================================================
module iir_lpf_cascade #(
    parameter IN_WIDTH   = 28,
    parameter FRAC_WIDTH = 32
)(
    input                              clk,
    input                              rst_n,
    input                              en,
    input  [4:0]                       shift_k,    // 所有级共用的 tau
    input  [2:0]                       order,      // 1..4 (其他值视为 1)
    input  signed [IN_WIDTH-1:0]       din,
    output reg signed [IN_WIDTH-1:0]   dout,
    output reg                         valid_out
);

    // ---- 4 级 EMA 级联 (各级数据 / valid 信号) -------------------------------
    wire signed [IN_WIDTH-1:0] y1, y2, y3, y4;
    wire                       v1, v2, v3, v4;

    iir_lpf_ema #(.IN_WIDTH(IN_WIDTH), .FRAC_WIDTH(FRAC_WIDTH)) u_stage1 (
        .clk(clk), .rst_n(rst_n), .en(en),
        .shift_k(shift_k), .din(din), .dout(y1), .valid_out(v1)
    );

    iir_lpf_ema #(.IN_WIDTH(IN_WIDTH), .FRAC_WIDTH(FRAC_WIDTH)) u_stage2 (
        .clk(clk), .rst_n(rst_n), .en(v1),
        .shift_k(shift_k), .din(y1), .dout(y2), .valid_out(v2)
    );

    iir_lpf_ema #(.IN_WIDTH(IN_WIDTH), .FRAC_WIDTH(FRAC_WIDTH)) u_stage3 (
        .clk(clk), .rst_n(rst_n), .en(v2),
        .shift_k(shift_k), .din(y2), .dout(y3), .valid_out(v3)
    );

    iir_lpf_ema #(.IN_WIDTH(IN_WIDTH), .FRAC_WIDTH(FRAC_WIDTH)) u_stage4 (
        .clk(clk), .rst_n(rst_n), .en(v3),
        .shift_k(shift_k), .din(y3), .dout(y4), .valid_out(v4)
    );

    // ---- order 选择最终输出 -------------------------------------------------
    always @(*) begin
        case (order)
            3'd1:    begin dout = y1; valid_out = v1; end
            3'd2:    begin dout = y2; valid_out = v2; end
            3'd3:    begin dout = y3; valid_out = v3; end
            3'd4:    begin dout = y4; valid_out = v4; end
            default: begin dout = y1; valid_out = v1; end  // 0 或非法值视为 1 阶
        endcase
    end

endmodule
