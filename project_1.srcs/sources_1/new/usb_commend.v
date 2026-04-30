`timescale 1ns / 1ps
// =============================================================================
//  usb_commend.v  (原 uart_commend.v 改名而来)
//
//  字节流级指令/数据协议解析器。
//  本模块 *不* 关心物理层, 只处理字节流:
//      - 输入: rec_data[7:0] + rec_done 脉冲  (每到一字节)
//      - 输出: send_en / send_data[7:0]       (等 tx_done 脉冲确认)
//
//  因此它对 UART / FT245BL USB-FIFO 都适用。当前工程通过 ft245_rx/ft245_tx
//  对接 FT245BL 芯片, 本模块保留对外纯字节流接口, 未来替换物理层无需修改。
//
//  支持的指令 (ASCII, 以 \r\n 或 \n 结尾):
//      FREQ:<十进制>   中心频率 (48bit 频率字)
//      KP:<十进制>     PLL 比例系数 (16bit)
//      KI:<十进制>     PLL 积分系数 (16bit)
//      TAUX:<十进制>   X 路 IIR 平滑系数 (5bit)
//      TAUY:<十进制>   Y 路 IIR 平滑系数 (5bit)
//      PHAS:<十进制>   tx1 相位偏移 (48bit)
//      FRQ2:<十进制>   tx1 频率字 (48bit)
//      FRQ3:<十进制>   tx2 频率字 (48bit)
//      XYOUT           开启 48 字节数据帧周期性回传
//      stop            关闭数据帧回传
//
//  回传数据帧 (80 字节 / 640 bit, 大端):
//      [0..3]    0xA5_5A_A5_5A             同步头
//      [4..47]   11 × int32 (通道1/2/3 的各路 X/Y/DC)
//      [48..59]  3 × int32  (原始 ADC 采样 ch1/ch2/ch3)
//      [60..75]  2 × uint64 (PLL 锁定频率字 ch1/ch2)
//      [76..79]  1 × int32  (lock_flags: bit0=ch1, bit1=ch2)
// =============================================================================
module usb_commend(
    input wire clk,
    input wire rst_n,
    input wire [7:0] rec_data,
    input wire rec_done,
    input wire tx_done,
    input wire [639:0] x_y_fir,    // 80字节完整回传帧
    input wire m_axis_data_tvalid_fir_x,
    output reg [47:0] center_freq,
    output reg [15:0] pll_kp,
    output reg [15:0] pll_ki,
    output reg [4:0]  tau_x,
    output reg [4:0]  tau_y,
    output reg [47:0] phase_offset,
    output reg [47:0] freq_word_2,
    output reg [47:0] freq_word_3,
    output reg send_en,
    output reg [7:0] send_data
);

    parameter IDLE = 3'd0;
    parameter REC_CMD = 3'd1;
    parameter REC_DATA = 3'd2;
    parameter SEND_RESPONSE = 3'd3;
    parameter WAIT_SEND = 3'd4;
    parameter SEND_XYDATA = 3'd5;
    parameter WAIT_XYDATA = 3'd6;
    parameter WAIT_DELAY = 3'd7;

    parameter CMD_FREQ = 4'd1;
    parameter CMD_KP   = 4'd2;
    parameter CMD_KI   = 4'd3;
    parameter CMD_TAUX = 4'd4;
    parameter CMD_TAUY = 4'd5;
    parameter CMD_PHAS = 4'd6;
    parameter CMD_XYOUT= 4'd7;
    parameter CMD_STOP = 4'd8;
    parameter CMD_FRQ2 = 4'd9;
    parameter CMD_FRQ3 = 4'd10;

    reg [2:0] curr_state;
    reg [3:0] cmd_type;
    reg [7:0] cmd_buffer[0:9];
    reg [3:0] cmd_cnt;
    reg [47:0] value_buffer;

    reg xy_data_enable;
    reg [7:0] byte_cnt;
    reg [639:0] xy_data_reg;       // 80 字节帧缓存
    reg new_data_ready;
    reg data_sending;

    // 帧长度 (字节), 随 x_y_fir 宽度一起调整
    localparam [7:0] FRAME_BYTES = 8'd80;

    reg [31:0] delay_cnt;
    parameter DELAY_1S = 32'd50_000_00;

    reg [7:0] success_msg[0:17];
    reg [7:0] error_msg[0:15];
    reg [4:0] msg_cnt;
    reg [4:0] msg_len;

    integer i;
    initial begin
        success_msg[0] = "C"; success_msg[1] = "o"; success_msg[2] = "m";
        success_msg[3] = "m"; success_msg[4] = "a"; success_msg[5] = "n";
        success_msg[6] = "d"; success_msg[7] = " "; success_msg[8] = "S";
        success_msg[9] = "u"; success_msg[10] = "c"; success_msg[11] = "c";
        success_msg[12] = "e"; success_msg[13] = "s"; success_msg[14] = "s";
        success_msg[15] = "!"; success_msg[16] = "\r"; success_msg[17] = "\n";

        error_msg[0] = "C"; error_msg[1] = "o"; error_msg[2] = "m";
        error_msg[3] = "m"; error_msg[4] = "a"; error_msg[5] = "n";
        error_msg[6] = "d"; error_msg[7] = " "; error_msg[8] = "E";
        error_msg[9] = "r"; error_msg[10] = "r"; error_msg[11] = "o";
        error_msg[12] = "r"; error_msg[13] = "!"; error_msg[14] = "\r";
        error_msg[15] = "\n";
    end

    reg m_axis_data_tvalid_fir_x_d1;
    wire m_axis_data_tvalid_fir_x_posedge;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            m_axis_data_tvalid_fir_x_d1 <= 1'b0;
        else
            m_axis_data_tvalid_fir_x_d1 <= m_axis_data_tvalid_fir_x;
    end

    assign m_axis_data_tvalid_fir_x_posedge = m_axis_data_tvalid_fir_x & ~m_axis_data_tvalid_fir_x_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xy_data_reg <= 640'd0;
            new_data_ready <= 1'b0;
        end else if (m_axis_data_tvalid_fir_x_posedge && xy_data_enable && !data_sending) begin
            xy_data_reg <= x_y_fir;
            new_data_ready <= 1'b1;
        end else if (curr_state == SEND_XYDATA && new_data_ready) begin
            new_data_ready <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
            cmd_type <= 4'd0;
            cmd_cnt <= 4'd0;
            value_buffer <= 48'd0;        
            msg_cnt <= 5'd0;
            msg_len <= 5'd0;

            center_freq <= 48'd433038425708;
            pll_kp <= 16'd500;
            pll_ki <= 16'd50;
            tau_x <= 5'd20;
            tau_y <= 5'd8;
            phase_offset <= 48'd0;
            freq_word_2 <= 48'd433038425708 + 48'd433038425;

            send_en <= 1'b0;
            send_data <= 8'd0;
            xy_data_enable <= 1'b0;
            byte_cnt <= 8'd0;
            data_sending <= 1'b0;
            delay_cnt <= 32'd0;
        end
        else begin
            case (curr_state)
                IDLE: begin
                    data_sending <= 1'b0;

                    if (rec_done) begin
                        cmd_buffer[0] <= rec_data;  
                        cmd_cnt <= 4'd1;           
                        curr_state <= REC_CMD;
                    end
                    else if (xy_data_enable && new_data_ready) begin
                        curr_state <= SEND_XYDATA;
                        byte_cnt <= 8'd0;
                    end
                end

                REC_CMD: begin
                    if (rec_done) begin
                        cmd_buffer[cmd_cnt] <= rec_data;

                        if (cmd_cnt == 4'd2) begin 
                            if (cmd_buffer[0] == "K" && cmd_buffer[1] == "P" && rec_data == ":") begin
                                cmd_type <= CMD_KP;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "K" && cmd_buffer[1] == "I" && rec_data == ":") begin
                                cmd_type <= CMD_KI;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else begin
                                cmd_cnt <= cmd_cnt + 1'b1;
                            end
                        end
                        else if (cmd_cnt == 4'd3) begin 
                            if (cmd_buffer[0] == "s" && cmd_buffer[1] == "t" && cmd_buffer[2] == "o" && rec_data == "p") begin
                                cmd_type <= CMD_STOP;
                                xy_data_enable <= 1'b0;
                                curr_state <= SEND_RESPONSE;
                                msg_cnt <= 5'd0;
                                msg_len <= 5'd18; 
                            end
                            else begin
                                cmd_cnt <= cmd_cnt + 1'b1;
                            end
                        end
                        else if (cmd_cnt == 4'd4) begin
                            if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "E" && cmd_buffer[3] == "Q" && rec_data == ":") begin
                                cmd_type <= CMD_FREQ;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "X" && rec_data == ":") begin
                                cmd_type <= CMD_TAUX;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "Y" && rec_data == ":") begin
                                cmd_type <= CMD_TAUY;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "P" && cmd_buffer[1] == "H" && cmd_buffer[2] == "A" && cmd_buffer[3] == "S" && rec_data == ":") begin
                                cmd_type <= CMD_PHAS;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "2" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ2;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "3" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ3;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "X" && cmd_buffer[1] == "Y" && cmd_buffer[2] == "O" && cmd_buffer[3] == "U" && rec_data == "T") begin
                                cmd_type <= CMD_XYOUT;
                                xy_data_enable <= 1'b1;
                                curr_state <= SEND_RESPONSE;
                                msg_cnt <= 5'd0;
                                msg_len <= 5'd18; 
                            end
                            else begin
                                cmd_cnt <= cmd_cnt + 1'b1;
                            end
                        end
                        else if (rec_data == "\r" || rec_data == "\n") begin
                            cmd_type <= 4'd0;
                            curr_state <= SEND_RESPONSE;
                            msg_cnt <= 5'd0;
                            msg_len <= 5'd16;  
                        end
                        else if (cmd_cnt >= 4'd8) begin
                            cmd_type <= 4'd0;
                            curr_state <= SEND_RESPONSE;
                            msg_cnt <= 5'd0;
                            msg_len <= 5'd16;  
                        end
                        else begin
                            cmd_cnt <= cmd_cnt + 1'b1;
                        end
                    end
                end

                REC_DATA: begin
                    if (rec_done) begin
                        if (rec_data >= "0" && rec_data <= "9") begin
                            value_buffer <= value_buffer * 48'd10 + (rec_data - "0"); 
                        end
                        else if (rec_data == "\r" || rec_data == "\n") begin
                            if (cmd_type == CMD_FREQ) begin
                                center_freq <= value_buffer;
                            end
                            else if (cmd_type == CMD_KP) begin
                                pll_kp <= value_buffer[15:0];
                            end
                            else if (cmd_type == CMD_KI) begin
                                pll_ki <= value_buffer[15:0];
                            end
                            else if (cmd_type == CMD_TAUX) begin
                                tau_x <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_TAUY) begin
                                tau_y <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_PHAS) begin
                                phase_offset <= value_buffer;
                            end
                            else if (cmd_type == CMD_FRQ2) begin
                                freq_word_2 <= value_buffer;
                            end
                            else if (cmd_type == CMD_FRQ3) begin
                                freq_word_3 <= value_buffer;
                            end
                            curr_state <= SEND_RESPONSE;
                            msg_cnt <= 5'd0;
                            msg_len <= 5'd18;  
                        end
                    end
                end

                SEND_RESPONSE: begin
                    if (!send_en && !tx_done) begin
                        send_en <= 1'b1;
                        if (cmd_type != 0) begin
                            send_data <= success_msg[msg_cnt];
                        end
                        else begin
                            send_data <= error_msg[msg_cnt];
                        end
                        curr_state <= WAIT_SEND;
                    end
                end

                WAIT_SEND: begin
                    if (tx_done) begin
                        send_en <= 1'b0;
                        if (msg_cnt < msg_len - 1) begin
                            msg_cnt <= msg_cnt + 1'b1;
                            curr_state <= SEND_RESPONSE;
                        end
                        else begin
                            curr_state <= IDLE;
                            cmd_cnt <= 4'd0;
                            cmd_type <= 4'd0;
                            value_buffer <= 48'd0;    
                        end
                    end
                end

                SEND_XYDATA: begin
                    if (rec_done) begin
                        cmd_buffer[0] <= rec_data;
                        cmd_cnt <= 4'd1;
                        curr_state <= REC_CMD;
                        data_sending <= 1'b0;
                        byte_cnt <= 8'd0;
                        send_en <= 1'b0;
                    end
                    else if (!xy_data_enable) begin
                        curr_state <= IDLE;
                        data_sending <= 1'b0;
                        byte_cnt <= 8'd0;
                    end
                    else if (!send_en && !tx_done) begin
                        send_en <= 1'b1;
                        data_sending <= 1'b1;
                        // byte_cnt = 0 -> 最高字节 (同步头 0xA5) 先发
                        send_data <= xy_data_reg[639-byte_cnt*8 -: 8];
                        curr_state <= WAIT_XYDATA;
                    end
                end

                WAIT_XYDATA: begin
                    if (rec_done) begin
                        cmd_buffer[0] <= rec_data;
                        cmd_cnt <= 4'd1;
                        curr_state <= REC_CMD;
                        data_sending <= 1'b0;
                        byte_cnt <= 8'd0;
                        send_en <= 1'b0;
                    end
                    else if (!xy_data_enable) begin
                        curr_state <= IDLE;
                        data_sending <= 1'b0;
                        byte_cnt <= 8'd0;
                        send_en <= 1'b0;  
                    end
                    else if (tx_done) begin
                        send_en <= 1'b0;
                        if (byte_cnt < FRAME_BYTES - 1) begin  
                            byte_cnt <= byte_cnt + 1'b1;
                            curr_state <= SEND_XYDATA;
                        end
                        else begin
                            byte_cnt <= 8'd0;
                            curr_state <= WAIT_DELAY; 
                            delay_cnt <= 32'd0;      
                            data_sending <= 1'b0;    
                        end
                    end
                end

                WAIT_DELAY: begin
                    if (rec_done) begin
                        cmd_buffer[0] <= rec_data;
                        cmd_cnt <= 4'd1;
                        curr_state <= REC_CMD;
                        delay_cnt <= 32'd0;
                    end
                    else if (!xy_data_enable) begin
                        curr_state <= IDLE;
                        delay_cnt <= 32'd0;
                    end
                    else if (delay_cnt >= DELAY_1S) begin
                        curr_state <= IDLE;         
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                default: curr_state <= IDLE;
            endcase
        end
    end

endmodule
