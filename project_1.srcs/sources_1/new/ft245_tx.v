`timescale 1ns / 1ps
// =============================================================================
//  ft245_tx.v
//
//  FT245BL 写时序驱动 (FPGA -> PC)
//  - 轮询 TXE#, 低 = 可写
//  - 把数据放到 D[7:0], 产生 WR 的高脉冲, 在 WR 下降沿 FT245 锁存
//
//  本模块对上层暴露的接口与 uart_send 完全一致:
//      input  send_en          (1 拍脉冲触发发送)
//      input  [7:0] send_data
//      output tx_done          (发送完成标志, 1 拍脉冲)
//  因此 usb_commend 可直接复用, 无需修改。
//
//  FT245BL 写周期时序 (数据手册):
//      T7  : WR Active Pulse Width        >= 50 ns   (WR 高电平持续)
//      T8  : WR to WR Pre-Charge Time     >= 50 ns
//      T9  : Data Setup Time before WR↓   >= 20 ns
//      T10 : Data Hold Time from WR↓      >= 0 ns
//      T11 : WR↓ to TXE# change           5 ~ 25 ns
//      T12 : TXE# inactive after WR cycle >= 80 ns
//
//  ※ usb_commend 把 send_en 保持为高直到看见 tx_done, 再拉低.
//    tx_done 那一拍本模块已回到 IDLE 而 send_en 仍为高, 若按电平触发会把同一
//    字节再发一次 (表现为每帧多一个首字节、应答显示 "CCommand ..."), 并使后续
//    字节与 tx_done 计数错位一拍. 因此这里只在 send_en 上升沿启动一次发送.
//
//  ※ D[7:0] 与 ft245_rx 共用. ST_WAIT 不驱动总线; 只有 bus_hold=0 (ft245_rx
//    既不在读、本拍也不发起读) 时才进入 WR 周期并驱动总线 (bus_owned=1).
//    ft245_rx 只在 bus_owned=0 时发起读. 读优先, 因此即使 TXE# 长时间为高
//    (PC 未取数) 卡在 ST_WAIT, 命令仍能被读入.
// =============================================================================

module ft245_tx #(
    parameter CLK_PERIOD_NS = 20,   // sys_clk 周期 (ns)
    parameter T_WR_HIGH_NS  = 80,   // WR 高脉冲持续 (>= T7=50)
    parameter T_WR_COOL_NS  = 160   // WR 低之后冷却 (>= T8 + T12 = 130)
)(
    input  wire       clk,
    input  wire       rst_n,

    // FT245 物理接口
    input  wire       ft_txe_n,    // TXE#: 低 = FT245 TX FIFO 可写
    output reg        ft_wr,       // WR  : 高 -> 低 边沿锁存
    output reg [7:0]  ft_d_out,    // 要驱动到三态总线的数据
    output reg        ft_d_oe,     // 三态总线输出使能 (1=驱动, 0=高阻)

    // 对上层的字节流接口 (与 uart_send 一致)
    input  wire       send_en,
    input  wire [7:0] send_data,
    output reg        tx_done,

    // 与 ft245_rx 的总线仲裁
    input  wire       bus_hold,     // ft245_rx 忙或本拍要发起读 (读优先)
    output wire       tx_busy,      // 本模块非空闲 (已接字节, 未完成)
    output wire       bus_owned     // 正在驱动 D[7:0] (WR 周期中)
);

    // ---- 周期计算 -----------------------------------------------------------
    localparam integer CNT_HIGH = (T_WR_HIGH_NS + CLK_PERIOD_NS - 1) / CLK_PERIOD_NS;
    localparam integer CNT_COOL = (T_WR_COOL_NS + CLK_PERIOD_NS - 1) / CLK_PERIOD_NS;

    // ---- 状态机 -------------------------------------------------------------
    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_WAIT    = 3'd1;   // 等 TXE# 低 (有空间可写)
    localparam [2:0] ST_WR_HIGH = 3'd2;   // 拉高 WR 并保持
    localparam [2:0] ST_WR_LOW  = 3'd3;   // 拉低 WR 完成锁存, 进入冷却
    localparam [2:0] ST_DONE    = 3'd4;   // 结束, 产生 tx_done 脉冲

    reg [2:0]  state;
    reg [15:0] cnt;

    assign tx_busy   = (state != ST_IDLE);
    assign bus_owned = (state == ST_WR_HIGH) || (state == ST_WR_LOW) || (state == ST_DONE);

    // ---- TXE# 三级同步 ------------------------------------------------------
    reg [2:0] txe_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) txe_sync <= 3'b111;
        else        txe_sync <= {txe_sync[1:0], ft_txe_n};
    end
    wire txe_ok = ~txe_sync[2];   // 低电平有效

    reg send_en_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) send_en_d <= 1'b0;
        else        send_en_d <= send_en;
    end
    wire send_start = send_en & ~send_en_d;

    // ---- 主状态机 -----------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= ST_IDLE;
            cnt      <= 16'd0;
            ft_wr    <= 1'b0;
            ft_d_out <= 8'd0;
            ft_d_oe  <= 1'b0;
            tx_done  <= 1'b0;
        end else begin
            tx_done <= 1'b0;   // 默认清零, 仅 DONE 那拍拉高 1 周期

            case (state)
                ST_IDLE: begin
                    ft_wr   <= 1'b0;
                    ft_d_oe <= 1'b0;          // 总线不驱动 (读方向/高阻)
                    if (send_start) begin
                        ft_d_out <= send_data; // 锁存要发送的字节
                        state    <= ST_WAIT;
                    end
                end

                ST_WAIT: begin
                    ft_d_oe <= 1'b0;
                    if (txe_ok && !bus_hold) begin
                        ft_d_oe <= 1'b1;       // 取得总线: 数据与 WR 同拍出现, WR 高 80ns 满足 T9
                        ft_wr   <= 1'b1;
                        state   <= ST_WR_HIGH;
                        cnt     <= 16'd0;
                    end
                end

                ST_WR_HIGH: begin
                    ft_wr   <= 1'b1;
                    ft_d_oe <= 1'b1;
                    if (cnt >= CNT_HIGH - 1) begin
                        ft_wr <= 1'b0;         // 下降沿, FT245 在此锁存数据
                        state <= ST_WR_LOW;
                        cnt   <= 16'd0;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_WR_LOW: begin
                    ft_wr   <= 1'b0;
                    ft_d_oe <= 1'b1;          // 冷却期间保持数据在总线上, 满足 T10
                    if (cnt >= CNT_COOL - 1) begin
                        state <= ST_DONE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_DONE: begin
                    tx_done <= 1'b1;
                    ft_d_oe <= 1'b0;          // 释放总线
                    state   <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
