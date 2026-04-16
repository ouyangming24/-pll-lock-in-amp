module uart_send(
    input wire clk,                  // 系统时钟
    input wire rst_n,               // 复位信号，低电平有效
    input wire send_en,             // 发送使能
    input wire [7:0] send_data,     // 要发送的数据
    output reg tx,                  // 发送端口
    output reg tx_done              // 发送完成标志
);

    // 状态定义
    parameter IDLE = 2'b00;         // 空闲状态
    parameter START = 2'b01;        // 起始位
    parameter SEND = 2'b10;         // 发送数据
    parameter STOP = 2'b11;         // 停止位
    
    // 波特率和时钟设置
    parameter CLK_FREQ = 50_000_000;    // 系统时钟频率 50MHz
    parameter BAUD_RATE = 115_200;      // 波特率 115200
    parameter BPS_CNT = CLK_FREQ/BAUD_RATE;  // 计数器最大值
    
    reg [1:0] curr_state;
    reg [15:0] clk_cnt;            // 使用16位确保兼容各种波特率
    reg [3:0] bit_cnt;             // 比特计数器
    reg [7:0] tx_data;             // 发送数据寄存器
    
    // 状态机实现
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
            tx <= 1'b1;
            tx_done <= 1'b0;
            clk_cnt <= 16'd0;
            bit_cnt <= 4'd0;
            tx_data <= 8'd0;
        end
        else begin
            case (curr_state)
                IDLE: begin
                    tx <= 1'b1;
                    tx_done <= 1'b0;
                    if (send_en) begin
                        curr_state <= START;
                        tx_data <= send_data;
                        clk_cnt <= 16'd0;
                    end
                end
                
                START: begin
                    tx <= 1'b0;
                    if (clk_cnt == BPS_CNT - 1) begin
                        curr_state <= SEND;
                        clk_cnt <= 16'd0;
                        bit_cnt <= 4'd0;
                    end
                    else
                        clk_cnt <= clk_cnt + 1'b1;
                end
                
                SEND: begin
                    tx <= tx_data[bit_cnt];
                    if (clk_cnt == BPS_CNT - 1) begin
                        clk_cnt <= 16'd0;
                        if (bit_cnt == 4'd7) begin
                            curr_state <= STOP;
                            bit_cnt <= 4'd0;
                        end
                        else
                            bit_cnt <= bit_cnt + 1'b1;
                    end
                    else
                        clk_cnt <= clk_cnt + 1'b1;
                end
                
                STOP: begin
                    tx <= 1'b1;
                    if (clk_cnt == BPS_CNT - 1) begin
                        curr_state <= IDLE;
                        tx_done <= 1'b1;
                        clk_cnt <= 16'd0;
                    end
                    else
                        clk_cnt <= clk_cnt + 1'b1;
                end
                
                default: curr_state <= IDLE;
            endcase
        end
    end

endmodule
