`timescale 1ns / 1ps
// =============================================================================
//  ft245_rx.v
//
//  FT245BL 读时序驱动 (PC -> FPGA)
//  - 轮询 RXF#, 低=有数据可读
//  - 拉 RD# 低 -> 等待数据有效 -> 锁存 -> 拉 RD# 高
//
//  本模块对上层暴露的接口与 uart_rec 完全一致:
//      output [7:0] rec_data
//      output       rec_done (1 拍脉冲, 表示一字节接收完成)
//  因此 usb_commend 可直接复用, 无需修改。
//
//  FT245BL 读周期时序 (数据手册):
//      T1  : RD# Active Pulse Width       >= 50 ns
//      T3  : RD# Active to Valid Data     20 ~ 50 ns
//      T5  : RD# Inactive to RXF# change  0  ~ 25 ns
//      T6  : RXF# inactive after RD cycle >= 80 ns
// =============================================================================

module ft245_rx #(
    parameter CLK_PERIOD_NS = 20,  // sys_clk 周期 (ns), 默认 50 MHz
    parameter T_RD_LOW_NS   = 80,  // RD# 低电平持续(含 T1+T3 余量) >= 50+50
    parameter T_RD_HIGH_NS  = 100  // RD# 高电平持续(含 T6 余量) >= 80
)(
    input  wire       clk,
    input  wire       rst_n,

    // FT245 物理接口
    input  wire       ft_rxf_n,    // RXF#: 低 = FT245 RX FIFO 有数据
    output reg        ft_rd_n,     // RD# : 输出给 FT245
    input  wire [7:0] ft_d_in,     // 从三态总线读入 (顶层接 inout)

    // 对上层的字节流接口 (与 uart_rec 一致)
    output reg [7:0]  rec_data,
    output reg        rec_done
);

    // ---- 周期计算: 用 ceil 保证不小于时序要求 -------------------------------
    localparam integer CNT_LOW  = (T_RD_LOW_NS  + CLK_PERIOD_NS - 1) / CLK_PERIOD_NS;
    localparam integer CNT_HIGH = (T_RD_HIGH_NS + CLK_PERIOD_NS - 1) / CLK_PERIOD_NS;

    // ---- 状态机 -------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_RD_LOW  = 3'd1;  // 拉低 RD# 并保持
    localparam [2:0] ST_LATCH   = 3'd2;  // 锁存数据, 同时拉高 RD#
    localparam [2:0] ST_RD_HIGH = 3'd3;  // 保持 RD# 高 (冷却)

    reg [2:0]  state;
    reg [15:0] cnt;

    // ---- RXF# 三级同步, 避免亚稳态 -----------------------------------------
    reg [2:0] rxf_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rxf_sync <= 3'b111;
        else        rxf_sync <= {rxf_sync[1:0], ft_rxf_n};
    end
    wire rxf_valid = ~rxf_sync[2];   // 低电平有效

    // ---- 主状态机 ----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            cnt      <= 16'd0;
            ft_rd_n  <= 1'b1;
            rec_data <= 8'd0;
            rec_done <= 1'b0;
        end else begin
            rec_done <= 1'b0;   // 默认清零, 仅在 LATCH 那拍拉高 1 周期

            case (state)
                ST_IDLE: begin
                    ft_rd_n <= 1'b1;
                    cnt     <= 16'd0;
                    if (rxf_valid) begin
                        ft_rd_n <= 1'b0;       // 立即拉低 RD#
                        state   <= ST_RD_LOW;
                    end
                end

                ST_RD_LOW: begin
                    ft_rd_n <= 1'b0;
                    if (cnt >= CNT_LOW - 1) begin
                        state <= ST_LATCH;
                        cnt   <= 16'd0;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_LATCH: begin
                    // 此拍 RD# 仍低, 数据有效 -> 锁存
                    rec_data <= ft_d_in;
                    rec_done <= 1'b1;          // 产生 1 拍脉冲
                    ft_rd_n  <= 1'b1;          // 拉高 RD# (完成本字节)
                    state    <= ST_RD_HIGH;
                    cnt      <= 16'd0;
                end

                ST_RD_HIGH: begin
                    ft_rd_n <= 1'b1;
                    if (cnt >= CNT_HIGH - 1) begin
                        state <= ST_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
