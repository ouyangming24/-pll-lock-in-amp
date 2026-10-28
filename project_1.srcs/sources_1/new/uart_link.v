`timescale 1ns / 1ps
// =============================================================================
//  uart_link.v
//
//  板载 CH340 USB 串口链路 (替代 eth_udp_link / FT245): 上位机命令下行 + 字节流上行
//  8N1, 无流控 (CH340 只接 TXD/RXD). 复用 uart_rec / uart_send.
//
//  对 usb_commend 呈现与 eth_udp_link / ft245_rx / ft245_tx 相同的字节接口 (clk 域):
//    下行: uart_rxd → uart_rec → RX FIFO → rec_data / rec_done
//          usb_commend 发应答 / 示波器包期间 rx_ready=0 不收字节, 而 PC 不会停发,
//          所以必须先进 FIFO; rx_pending = FIFO 非空.
//    上行: send_en (电平, 见到 tx_done 才撤) → 取上升沿启动 uart_send.
//          uart_send 在 IDLE 只看 send_en 电平, 直接接会把同一字节发两遍.
//          tx_busy 从启动保持到 tx_done, usb_commend 据此等串口发完再送下一字节.
//
//  LED: pl_led1 约 1 Hz 闪烁 = 逻辑在跑; pl_led2 亮 50 ms = 收到 / 发出字节
// =============================================================================
module uart_link #(
    parameter CLK_FREQ   = 65_000_000,
    parameter BAUD_RATE  = 921_600,
    parameter RX_FIFO_AW = 8                 // RX FIFO 深度 2^AW 字节
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       uart_rxd,              // ← CH340 TXD
    output wire       uart_txd,              // → CH340 RXD

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

    // -------------------------------------------------------------------------
    // RX: uart_rec → FIFO → usb_commend
    // -------------------------------------------------------------------------
    wire [7:0] rx_byte;
    wire       rx_vld;

    uart_rec #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE)
    ) u_uart_rec (
        .clk      (clk),
        .rst_n    (rst_n),
        .rx       (uart_rxd),
        .rec_data (rx_byte),
        .rec_done (rx_vld)
    );

    reg [7:0]            rx_fifo [0:(1<<RX_FIFO_AW)-1];
    reg [RX_FIFO_AW-1:0] rx_wp, rx_rp;
    wire rx_empty = (rx_wp == rx_rp);
    wire rx_full  = (rx_wp + 1'b1 == rx_rp);
    wire rx_push  = rx_vld && !rx_full;
    // !rec_done: 本拍送出的字节可能让 usb_commend 下一拍转入 SEND_RESPONSE (rx_ready 变 0),
    // 同拍再弹会丢字节
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

    // -------------------------------------------------------------------------
    // TX: usb_commend → uart_send
    // -------------------------------------------------------------------------
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
        .tx        (uart_txd),
        .tx_done   (tx_done)
    );

    // -------------------------------------------------------------------------
    // LED
    // -------------------------------------------------------------------------
    localparam ACT_CYCLES = CLK_FREQ / 20;     // 50 ms

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
