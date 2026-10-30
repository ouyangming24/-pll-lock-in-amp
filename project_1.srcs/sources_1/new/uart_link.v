`timescale 1ns / 1ps
// =============================================================================
//  uart_link.v
//
//  板载 CH340 USB 串口链路: 上位机命令下行 + 字节流上行
//  8N1, 无流控. 复用 uart_rec / uart_send.
//  波特率由 baud_div (每比特时钟数) 运行时可调; 上电默认见 BAUD_RATE.
// =============================================================================
module uart_link #(
    parameter CLK_FREQ   = 65_000_000,
    parameter BAUD_RATE  = 115_200,
    parameter RX_FIFO_AW = 8
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       uart_rxd,
    output wire       uart_txd,

    input  wire [15:0] baud_div,     // 每比特 clk 拍数 (usb_commend 维护)

    output reg  [7:0] rec_data,
    output reg        rec_done,
    input  wire       rx_ready,
    output wire       rx_pending,
    input  wire       send_en,
    input  wire [7:0] send_data,
    output wire       tx_done,
    output reg        tx_busy,

    output wire       pl_led1,
    output wire       pl_led2
);

    wire [7:0] rx_byte;
    wire       rx_vld;

    uart_rec #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_rec (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx       (uart_rxd),
        .baud_div (baud_div),
        .rec_data (rx_byte),
        .rec_done (rx_vld)
    );

    reg [7:0]            rx_fifo [0:(1<<RX_FIFO_AW)-1];
    reg [RX_FIFO_AW-1:0] rx_wp, rx_rp;
    wire rx_empty = (rx_wp == rx_rp);
    wire rx_full  = (rx_wp + 1'b1 == rx_rp);
    wire rx_push  = rx_vld && !rx_full;
    wire rx_pop   = !rx_empty && rx_ready && !rec_done;

    assign rx_pending = !rx_empty;

    always @(posedge clk)
        if (rx_push) rx_fifo[rx_wp] <= rx_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_wp    <= {RX_FIFO_AW{1'b0}};
            rx_rp    <= {RX_FIFO_AW{1'b0}};
            rec_data <= 8'd0;
            rec_done <= 1'b0;
        end else begin
            rec_done <= 1'b0;
            if (rx_push)
                rx_wp <= rx_wp + 1'b1;
            if (rx_pop) begin
                rec_data <= rx_fifo[rx_rp];
                rec_done <= 1'b1;
                rx_rp    <= rx_rp + 1'b1;
            end
        end
    end

    reg  send_en_d;
    wire send_start = send_en && !send_en_d && !tx_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            send_en_d <= 1'b0;
            tx_busy   <= 1'b0;
        end else begin
            send_en_d <= send_en;
            if (send_start)
                tx_busy <= 1'b1;
            else if (tx_done)
                tx_busy <= 1'b0;
        end
    end

    uart_send #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_send (
        .clk       (clk),
        .rst_n     (rst_n),
        .send_en   (send_start),
        .send_data (send_data),
        .baud_div  (baud_div),
        .tx        (uart_txd),
        .tx_done   (tx_done)
    );

    localparam ACT_CYCLES = CLK_FREQ / 20;

    reg [25:0] blink_cnt;
    reg [23:0] act_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blink_cnt <= 26'd0;
            act_cnt   <= 24'd0;
        end else begin
            blink_cnt <= blink_cnt + 1'b1;
            if (rx_vld || tx_done)
                act_cnt <= ACT_CYCLES;
            else if (act_cnt != 0)
                act_cnt <= act_cnt - 1'b1;
        end
    end

    assign pl_led1 = blink_cnt[25];
    assign pl_led2 = (act_cnt != 0);

endmodule
