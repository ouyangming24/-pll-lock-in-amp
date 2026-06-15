`timescale 1ns / 1ps
// =============================================================================
//  phase_sin_cos_lut.v
//
//  48bit 相位 → 14bit sin/cos (BRAM 查表). 每拍更新, 不重配 DDS.
//  地址取 phase[47:36] (4096 点, ~0.088° 分辨率).
// =============================================================================
module phase_sin_cos_lut #(
    parameter ADDR_W = 12,
    parameter DATA_W = 14
)(
    input  wire               clk,
    input  wire [47:0]        phase,
    output reg signed [DATA_W-1:0] sin_o,
    output reg signed [DATA_W-1:0] cos_o
);

    localparam DEPTH = (1 << ADDR_W);
    localparam COS_OFF = (1 << (ADDR_W - 2));   // +90° = +π/2

    (* rom_style = "block" *) reg signed [DATA_W-1:0] sin_rom [0:DEPTH-1];

    integer i;
    real ang;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1) begin
            ang = 2.0 * 3.14159265358979 * i / DEPTH;
            sin_rom[i] = $rtoi($sin(ang) * 8191.0);
        end
    end

    wire [ADDR_W-1:0] addr_sin = phase[47:48-ADDR_W];
    wire [ADDR_W-1:0] addr_cos = addr_sin + COS_OFF[ADDR_W-1:0];

    reg signed [DATA_W-1:0] sin_rd, cos_rd;
    always @(posedge clk) begin
        sin_rd <= sin_rom[addr_sin];
        cos_rd <= sin_rom[addr_cos];
        sin_o  <= sin_rd;
        cos_o  <= cos_rd;
    end

endmodule
