module uart_rec(
    input wire clk,                  // 系统时钟
    input wire rst_n,               // 复位信号，低电平有效
    input wire rx,                  // 接收端口
    output reg [7:0] rec_data,      // 接收到的数据
    output reg rec_done             // 接收完成标志
);

    // 状态定义
    parameter IDLE = 2'b00;         // 空闲状态
    parameter START = 2'b01;        // 起始位
    parameter REC = 2'b10;          // 接收数据
    parameter STOP = 2'b11;         // 停止位
    
    // 波特率和时钟设置
    parameter CLK_FREQ = 50_000_000;    // 系统时钟频率 50MHz
    parameter BAUD_RATE = 115_200;      // 波特率 115200
    parameter BPS_CNT = CLK_FREQ/BAUD_RATE;  // 计数器最大值
    parameter HALF_BPS_CNT = (BPS_CNT + 1)/2;  // 半个波特率周期，向上取整
    
    reg [1:0] curr_state;
    reg [15:0] clk_cnt;            // 使用16位确保兼容各种波特率
    reg [3:0] bit_cnt;             // 比特计数器
    reg rx_sync1, rx_sync2;        // 同步寄存器
    
    // 双寄存器同步
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end
        else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end
    
    // 状态机实现
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
            clk_cnt <= 16'd0;
            bit_cnt <= 4'd0;
            rec_data <= 8'd0;
            rec_done <= 1'b0;
        end
        else begin
            case (curr_state)
                IDLE: begin
                    rec_done <= 1'b0;
                    if (rx_sync2 == 1'b0) begin  // 检测到起始位
                        curr_state <= START;
                        clk_cnt <= 16'd0;
                    end
                end
                
                START: begin
                    if (clk_cnt == HALF_BPS_CNT - 1) begin  // 在起始位中间采样
                        if (rx_sync2 == 1'b0) begin  // 确认起始位
                            curr_state <= REC;
                            clk_cnt <= 16'd0;
                            bit_cnt <= 4'd0;
                        end
                        else
                            curr_state <= IDLE;
                    end
                    else
                        clk_cnt <= clk_cnt + 1'b1;
                end
                
                REC: begin
                    if (clk_cnt == BPS_CNT - 1) begin
                        clk_cnt <= 16'd0;
                        rec_data[bit_cnt] <= rx_sync2;
                        if (bit_cnt == 4'd7) begin
                            curr_state <= STOP;
                        end
                        else
                            bit_cnt <= bit_cnt + 1'b1;
                    end
                    else
                        clk_cnt <= clk_cnt + 1'b1;
                end
                
                STOP: begin
                    if (clk_cnt == BPS_CNT - 1) begin
                        if (rx_sync2 == 1'b1) begin  // 检查停止位
                            rec_done <= 1'b1;
                        end
                        curr_state <= IDLE;
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
