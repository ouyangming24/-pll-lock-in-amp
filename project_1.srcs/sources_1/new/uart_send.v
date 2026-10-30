module uart_send #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       send_en,
    input  wire [7:0] send_data,
    input  wire [15:0] baud_div,   // 每比特时钟数; 0 则用 CLK_FREQ/BAUD_RATE
    output reg        tx,
    output reg        tx_done
);

    localparam [15:0] BPS_DEFAULT = CLK_FREQ / BAUD_RATE;

    parameter IDLE  = 2'b00;
    parameter START = 2'b01;
    parameter SEND  = 2'b10;
    parameter STOP  = 2'b11;

    wire [15:0] bps = (baud_div == 16'd0) ? BPS_DEFAULT : baud_div;

    reg [1:0]  curr_state;
    reg [15:0] clk_cnt;
    reg [3:0]  bit_cnt;
    reg [7:0]  tx_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
            tx         <= 1'b1;
            tx_done    <= 1'b0;
            clk_cnt    <= 16'd0;
            bit_cnt    <= 4'd0;
            tx_data    <= 8'd0;
        end else begin
            case (curr_state)
                IDLE: begin
                    tx      <= 1'b1;
                    tx_done <= 1'b0;
                    if (send_en) begin
                        curr_state <= START;
                        tx_data    <= send_data;
                        clk_cnt    <= 16'd0;
                    end
                end

                START: begin
                    tx <= 1'b0;
                    if (clk_cnt == bps - 16'd1) begin
                        curr_state <= SEND;
                        clk_cnt    <= 16'd0;
                        bit_cnt    <= 4'd0;
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                SEND: begin
                    tx <= tx_data[bit_cnt];
                    if (clk_cnt == bps - 16'd1) begin
                        clk_cnt <= 16'd0;
                        if (bit_cnt == 4'd7) begin
                            curr_state <= STOP;
                            bit_cnt    <= 4'd0;
                        end else
                            bit_cnt <= bit_cnt + 4'd1;
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                STOP: begin
                    tx <= 1'b1;
                    if (clk_cnt == bps - 16'd1) begin
                        curr_state <= IDLE;
                        tx_done    <= 1'b1;
                        clk_cnt    <= 16'd0;
                    end else
                        clk_cnt <= clk_cnt + 16'd1;
                end

                default: curr_state <= IDLE;
            endcase
        end
    end

endmodule
