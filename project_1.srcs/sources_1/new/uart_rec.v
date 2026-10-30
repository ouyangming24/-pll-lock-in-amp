module uart_rec #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    input  wire [15:0] baud_div,   // 每比特时钟数; 0 则用 CLK_FREQ/BAUD_RATE
    output reg  [7:0] rec_data,
    output reg        rec_done
);

    localparam [15:0] BPS_DEFAULT = CLK_FREQ / BAUD_RATE;

    parameter IDLE  = 2'b00;
    parameter START = 2'b01;
    parameter REC   = 2'b10;
    parameter STOP  = 2'b11;

    wire [15:0] bps  = (baud_div == 16'd0) ? BPS_DEFAULT : baud_div;
    wire [15:0] half = (bps + 16'd1) >> 1;

    reg [1:0]  curr_state;
    reg [15:0] clk_cnt;
    reg [3:0]  bit_cnt;
    reg        rx_sync1, rx_sync2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
            clk_cnt    <= 16'd0;
            bit_cnt    <= 4'd0;
            rec_data   <= 8'd0;
            rec_done   <= 1'b0;
        end else begin
            case (curr_state)
                IDLE: begin
                    rec_done <= 1'b0;
                    if (rx_sync2 == 1'b0) begin
                        curr_state <= START;
                        clk_cnt    <= 16'd0;
                    end
                end

                START: begin
                    if (clk_cnt == half - 16'd1) begin
                        if (rx_sync2 == 1'b0) begin
                            curr_state <= REC;
                            clk_cnt    <= 16'd0;
                            bit_cnt    <= 4'd0;
                        end else
                            curr_state <= IDLE;
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                REC: begin
                    if (clk_cnt == bps - 16'd1) begin
                        clk_cnt <= 16'd0;
                        rec_data[bit_cnt] <= rx_sync2;
                        if (bit_cnt == 4'd7)
                            curr_state <= STOP;
                        else
                            bit_cnt <= bit_cnt + 4'd1;
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                STOP: begin
                    if (clk_cnt == bps - 16'd1) begin
                        if (rx_sync2 == 1'b1)
                            rec_done <= 1'b1;
                        curr_state <= IDLE;
                        clk_cnt    <= 16'd0;
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                default: curr_state <= IDLE;
            endcase
        end
    end

endmodule
