module uart_xy (
    input wire clk,              // 时钟信号
    input wire rst_n,            // 复位信号
    input wire [127:0] data_in,   // 输入的数据，从160位改为128位
    input wire start_send,       // 开始发送信号
    output wire uart_txd,        // UART发送端口
    output reg tx_flag           // 发送标志，表示发送忙
);


    reg [7:0] data_chunk;        // 每次发送的8位数据块
    reg [3:0] chunk_count;       // 数据块计数器，调整为4位以适应16个8位数据块
    reg [2:0] state;             // 状态机状态
    reg send_enable;             // 发送使能信号
    reg [26:0] delay_counter;    // 延迟计数器
    reg delay_enable;            // 延迟使能信号
    wire tx_done;                // 从uart_send模块获取的发送完成信号

    localparam IDLE = 3'b000;
    localparam DATA = 3'b001;
    localparam DELAY_SEND = 3'b010;
    localparam NEWLINE = 3'b011;
    localparam DELAY = 3'b100;

    // 串口发送模块实例，修改参数名称以匹配uart_send模块定义
    uart_send u_uart_send(
        .clk(clk),
        .rst_n(rst_n),
        .send_en(send_enable),
        .send_data(data_chunk),
        .tx(uart_txd),
        .tx_done(tx_done)
    );

    // tx_flag信号处理逻辑（发送忙信号）
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            tx_flag <= 1'b0;
        else if (send_enable)
            tx_flag <= 1'b1;       // 开始发送时设置忙标志
        else if (tx_done)
            tx_flag <= 1'b0;       // 收到发送完成信号时清除忙标志
    end

    // 数据发送控制逻辑
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            chunk_count <= 16;   // 调整为16，对应128位数据（16个8位数据块）
            send_enable <= 0;
            state <= IDLE;
            data_chunk <= 8'b0;
            delay_counter <= 0;
            delay_enable <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (start_send) begin
                        chunk_count <= 16;     // 初始化为16个数据块
                        send_enable <= 0;      // 开始发送第一个数据块
                        state <= DATA;
                    end
                end

                DATA: begin
                    if (chunk_count > 0) begin        // 等待上一个数据块发送完成
                        if (!tx_flag) begin
                            // 使用移位操作选择要发送的8位数据块
                            data_chunk  <= (data_in >> ((chunk_count-1) * 8)) & 8'hFF;
                            send_enable <= 1;
                            state <= DELAY_SEND;  // 添加一个新的状态用于延迟清除
                        end
                    end else begin
                        send_enable <= 0;
                        state <= DELAY;  // 进入延迟状态
                    end
                end
                
                DELAY_SEND: begin
                    send_enable <= 0;  // 在下一周期清除 send_enable
                    chunk_count <= chunk_count - 1;
                    state <= DATA;  // 回到数据发送状态，准备发送下一个块
                end
                
//                NEWLINE: begin
//                    if (!tx_flag) begin        // 等待发送完成
//                        data_chunk <= 8'h0A;   // 发送换行符
//                        send_enable <= 1;
//                        state <= DELAY;        // 进入延迟状态
//                    end
//                end

                DELAY: begin
                    if (delay_counter < 27'd99999999) begin
                        delay_counter <= delay_counter + 1;
                        send_enable <= 0;
                    end else begin
                        delay_counter <= 0;
                        delay_enable <= 0;
                        state <= IDLE;         // 延迟结束后回到IDLE状态
                    end
                end
            endcase
        end
    end

endmodule
