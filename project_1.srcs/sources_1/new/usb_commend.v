`timescale 1ns / 1ps
// =============================================================================
//  usb_commend.v  (???uart_commend.v ????????)
//
//  ???????????/????????????????
//  ??????*?? ???????????? ???????????:
//      - ?????: rec_data[7:0] + rec_done ??????  (???????????)
//      - ?????: send_en / send_data[7:0]       (??tx_done ????????)
//
//  ??????? UART / FT245BL USB-FIFO ????????????????????????? ft245_rx/ft245_tx
//  ???? FT245BL ??????, ????????????????????????? ????????????????????????????
//
//  ??????????????(ASCII, ??\r\n ???\n ???):
//      FREQ:<??????     ???????? (48bit ???????
//      KP:<??????       PLL ???????? (16bit)
//      KI:<??????       PLL ???????? (16bit)
//      TAUX:<??????     X ??IIR ??????? (5bit)
//      TAUY:<??????     Y ??IIR ??????? (5bit)
//      PHAS:<??????     tx1 ?????? (48bit)
//      FRQ2:<??????     tx1 ???????(48bit)
//      FRQ3:<??????     tx2 ???????(48bit)
//      LOCKSWY:<??????  ???PLL ?????: Y ???????????????(28bit, ??LOCK ?????)
//      LOCKTHX:<??????  ???PLL ?????: X ???????????????(28bit, ??????LOCK ?????)
//      XYOUT             ??????????????????????
//      stop              ????????????????
//
//  ??????????(80 ????? / 640 bit, ??):
//      [0..3]    0xA5_5A_A5_5A             ?????
//      [4..47]   11 ?? int32 (?????1/2/3 ???????X/Y/DC)
//      [48..59]  3 ?? int32  (????? ADC ???? ch1/ch2/ch3)
//      [60..75]  2 ?? uint64 (PLL ????????????ch1/ch2)
//      [76..79]  1 ?? int32  (lock_flags: bit0=ch1, bit1=ch2)
// =============================================================================
module usb_commend(
    input wire clk,
    input wire rst_n,
    input wire [7:0] rec_data,
    input wire rec_done,
    input wire tx_done,
    input wire [831:0] x_y_fir,    // 104 字节回传帧 (含 3 路参考频率字回读)
    input wire m_axis_data_tvalid_fir_x,
    output reg [47:0] center_freq,
    output reg [15:0] pll_kp,
    output reg [15:0] pll_ki,
    output reg [4:0]  tau1_x,
    output reg [4:0]  tau1_y,
    output reg [4:0]  tau2_x,
    output reg [4:0]  tau2_y,
    // ★ 通道3 三路谐波 IIR 时间常数 (X/Y 共用, 与商用 SR830 一致)
    output reg [4:0]  tau21,    // ch3 @ 2F1+F2
    output reg [4:0]  tau12,    // ch3 @ F1+2F2
    output reg [4:0]  tau11,    // ch3 @ F1+F2
    output reg [4:0]  tau_dc,   // ch3 DC 通路 (本来就是单一 IIR)
    output reg [47:0] phase_offset,
    output reg [47:0] freq_word_2,
    output reg [47:0] freq_word_3,
    // ★ 通道3 三路开环锁相放大器的参考频率 (PLL 注释期间可手动下发, 平时可由 PLL 输出运算得到)
    output reg [47:0] freq_word_21,           // ch3 @ 2F1+F2 ref_freq (FRQ21)
    output reg [47:0] freq_word_12,           // ch3 @ F1+2F2 ref_freq (FRQ12)
    output reg [47:0] freq_word_11,           // ch3 @ F1+F2  ref_freq (FRQ11)
    output reg signed [27:0] sweep_thres,    // ???PLL Y ??LOCK ????? (LOCKSWY)
    output reg signed [27:0] lock_x_thres,   // ???PLL X ???? LOCK ????? (LOCKTHX)
    // ★ 通道3 三路 ref_freq 来源选择 (REFMODE 命令下发)
    //   0 = 手动 (用 FRQ21/FRQ12/FRQ11 三个值, 默认)
    //   1 = 自动 (硬件实时: n*pll_freq_ch1 + m*pll_freq_ch2, 系数由 OSC1/2/3 下发)
    output reg ref_freq_auto,
    // ★ 通道3 三路振荡器谐波系数 (OSC1/OSC2/OSC3 命令, 值打包: [15:8]=n, [7:0]=m)
    output reg [7:0] osc1_n, osc1_m,
    output reg [7:0] osc2_n, osc2_m,
    output reg [7:0] osc3_n, osc3_m,
    // ★ 三路振荡器 ADC 输入源 (OSRC1/2/3 命令: 0=CH3, 1=CH4, 2=CH3-CH4 差分)
    output reg [1:0] osc1_src,
    output reg [1:0] osc2_src,
    output reg [1:0] osc3_src,
    // ★ 通道3 4 路 IIR 阶数 (各路独立设置, ORD21/ORD12/ORD11/ORDDC 命令下发)
    //   取值 1..4, 等效 6/12/18/24 dB/oct 阻带斜率 (仿 SR860 / Zurich MFLI 每通道独立 slope)
    //   非法值 (0 或 >4) 在 iir_lpf_cascade 内被视为 1 阶
    output reg [2:0] order21,    // ch3 @ 2F1+F2  PSD 阶数
    output reg [2:0] order12,    // ch3 @ F1+2F2  PSD 阶数
    output reg [2:0] order11,    // ch3 @ F1+F2   PSD 阶数
    output reg [2:0] order_dc,   // ch3 DC 通路   IIR 阶数
    // ★ 信号发生器 (DAC904) 控制
    //   dac_src_mode: 0=内部DDS(指定频率/相位下发), 1=跟随CH1锁定频率, 2=跟随CH2锁定频率
    output reg [1:0]  dac_src_mode,    // DMOD 命令
    output reg [47:0] dac_freq_word,   // DFRQ 命令: 内部DDS频率字 (48bit)
    output reg [47:0] dac_phase_word,  // DPHS 命令: 内部DDS相位字 (48bit)
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

    parameter CMD_FREQ    = 6'd1;
    parameter CMD_KP      = 6'd2;
    parameter CMD_KI      = 6'd3;
    parameter CMD_PHAS    = 6'd6;
    parameter CMD_XYOUT   = 6'd7;
    parameter CMD_STOP    = 6'd8;
    parameter CMD_FRQ2    = 6'd9;
    parameter CMD_FRQ3    = 6'd10;
    parameter CMD_LOCKSWY = 6'd11;
    parameter CMD_LOCKTHX = 6'd12;
    parameter CMD_TAU1X   = 6'd13;
    parameter CMD_TAU1Y   = 6'd14;
    parameter CMD_TAU2X   = 6'd15;
    parameter CMD_TAU2Y   = 6'd16;
    parameter CMD_TAU21   = 6'd17;
    parameter CMD_TAU12   = 6'd18;
    parameter CMD_TAU11   = 6'd19;
    parameter CMD_TAUDC   = 6'd20;
    parameter CMD_FRQ21   = 6'd21;
    parameter CMD_FRQ12   = 6'd22;
    parameter CMD_FRQ11   = 6'd23;
    parameter CMD_REFMODE = 6'd24;
    parameter CMD_ORD21   = 6'd25;
    parameter CMD_ORD12   = 6'd26;
    parameter CMD_ORD11   = 6'd27;
    parameter CMD_ORDDC   = 6'd28;
    parameter CMD_DMOD    = 6'd29;
    parameter CMD_DFRQ    = 6'd30;
    parameter CMD_DPHS    = 6'd31;   // 信号发生器内部DDS相位字 (48bit)
    parameter CMD_OSC1    = 6'd32;   // 振荡器1: n*F1+m*F2 系数 ([15:8]=n,[7:0]=m)
    parameter CMD_OSC2    = 6'd33;   // 振荡器2
    parameter CMD_OSC3    = 6'd34;   // 振荡器3
    parameter CMD_OSRC1   = 6'd35;   // 振荡器1 ADC 源: 0=CH3, 1=CH4, 2=CH3-CH4
    parameter CMD_OSRC2   = 6'd36;
    parameter CMD_OSRC3   = 6'd37;

    reg [2:0] curr_state;
    reg [5:0] cmd_type;
    reg [7:0] cmd_buffer[0:9];
    reg [3:0] cmd_cnt;
    reg [47:0] value_buffer;

    reg xy_data_enable;
    reg [7:0] byte_cnt;
    reg [831:0] xy_data_reg;       // 104 字节回传帧寄存
    reg new_data_ready;
    reg data_sending;

    // ??????(?????), ???x_y_fir ??????????
    localparam [7:0] FRAME_BYTES = 8'd104;

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
            xy_data_reg <= 832'd0;
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
            cmd_type <= 6'd0;
            cmd_cnt <= 4'd0;
            value_buffer <= 48'd0;        
            msg_cnt <= 5'd0;
            msg_len <= 5'd0;

            center_freq <= 48'd433038425708;
            pll_kp <= 16'd500;
            pll_ki <= 16'd50;
            tau1_x <= 5'd20;
            tau1_y <= 5'd8;
            tau2_x <= 5'd20;
            tau2_y <= 5'd8;
            tau21   <= 5'd2;
            tau12   <= 5'd2;
            tau11   <= 5'd2;
            tau_dc  <= 5'd2;
            phase_offset <= 48'd0;
            freq_word_2 <= 48'd433038425708 + 48'd433038425;
            // ★ 通道3 三路 ref_freq 默认值 (对应 F1=50k, F2=60k 时的 2F1+F2 / F1+2F2 / F1+F2)
            freq_word_21 <= 48'd692861481134;   // 160 kHz
            freq_word_12 <= 48'd736165323705;   // 170 kHz
            freq_word_11 <= 48'd476342268280;   // 110 kHz
            ref_freq_auto <= 1'b0;              // 默认手动; GUI 连接后会发 REFMODE:1
            // ★ 振荡器默认系数: 2F1+F2 / F1+2F2 / F1+F2
            osc1_n <= 8'd2;  osc1_m <= 8'd1;
            osc2_n <= 8'd1;  osc2_m <= 8'd2;
            osc3_n <= 8'd1;  osc3_m <= 8'd1;
            osc1_src <= 2'd0;   // 默认 CH3
            osc2_src <= 2'd0;
            osc3_src <= 2'd0;
            // ★ 4 路 IIR 阶数默认全 1 阶 (6 dB/oct, 与原 iir_lpf_ema 行为完全一致)
            order21       <= 3'd1;
            order12       <= 3'd1;
            order11       <= 3'd1;
            order_dc      <= 3'd1;
            // ★ 信号发生器默认: 内部DDS, ~50 kHz @ 65MHz (50000*2^48/65e6), 0 相位
            dac_src_mode   <= 2'd0;
            dac_freq_word  <= 48'd216519212854;
            dac_phase_word <= 48'd0;
            // ???PLL ?????????????????(????, ???????????????????
            sweep_thres  <= 28'd100_000;   // |dc_y| > 100K ?????LOCK
            lock_x_thres <= 28'd300_000;   // LOCK ?????? |dc_x| ??> 300K ????

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
                            // 5 ????: FREQ: PHAS: FRQ2: FRQ3: XYOUT
                            if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "E" && cmd_buffer[3] == "Q" && rec_data == ":") begin
                                cmd_type <= CMD_FREQ;
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
                            // ★ 信号发生器 (DAC904): DMOD / DFRQ / DPHS (均为 4 字符命令)
                            else if (cmd_buffer[0] == "D" && cmd_buffer[1] == "M" && cmd_buffer[2] == "O" && cmd_buffer[3] == "D" && rec_data == ":") begin
                                cmd_type <= CMD_DMOD;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "D" && cmd_buffer[1] == "F" && cmd_buffer[2] == "R" && cmd_buffer[3] == "Q" && rec_data == ":") begin
                                cmd_type <= CMD_DFRQ;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "D" && cmd_buffer[1] == "P" && cmd_buffer[2] == "H" && cmd_buffer[3] == "S" && rec_data == ":") begin
                                cmd_type <= CMD_DPHS;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            // ★ 通道3 振荡器谐波系数 OSC1/OSC2/OSC3 (值=[15:8]n,[7:0]m)
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "C" && cmd_buffer[3] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_OSC1;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "C" && cmd_buffer[3] == "2" && rec_data == ":") begin
                                cmd_type <= CMD_OSC2;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "C" && cmd_buffer[3] == "3" && rec_data == ":") begin
                                cmd_type <= CMD_OSC3;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else begin
                                cmd_cnt <= cmd_cnt + 1'b1;
                            end
                        end
                        else if (cmd_cnt == 4'd5) begin
                            // 6 ????: TAU1X: TAU1Y: TAU2X: TAU2Y: TAUDC: FRQ21: FRQ12: FRQ11:
                            if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "1" && cmd_buffer[4] == "X" && rec_data == ":") begin
                                cmd_type <= CMD_TAU1X;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "1" && cmd_buffer[4] == "Y" && rec_data == ":") begin
                                cmd_type <= CMD_TAU1Y;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "2" && cmd_buffer[4] == "X" && rec_data == ":") begin
                                cmd_type <= CMD_TAU2X;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "2" && cmd_buffer[4] == "Y" && rec_data == ":") begin
                                cmd_type <= CMD_TAU2Y;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "D" && cmd_buffer[4] == "C" && rec_data == ":") begin
                                cmd_type <= CMD_TAUDC;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            // ★ 通道3 三路谐波 IIR 时间常数 (X/Y 共用, 商用做法)
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "2" && cmd_buffer[4] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_TAU21;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "1" && cmd_buffer[4] == "2" && rec_data == ":") begin
                                cmd_type <= CMD_TAU12;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "1" && cmd_buffer[4] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_TAU11;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            // ★ 振荡器 ADC 输入源 OSRC1/2/3 (0=CH3, 1=CH4, 2=CH3-CH4)
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "R" && cmd_buffer[3] == "C" && cmd_buffer[4] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_OSRC1;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "R" && cmd_buffer[3] == "C" && cmd_buffer[4] == "2" && rec_data == ":") begin
                                cmd_type <= CMD_OSRC2;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "R" && cmd_buffer[3] == "C" && cmd_buffer[4] == "3" && rec_data == ":") begin
                                cmd_type <= CMD_OSRC3;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            // ★ 通道3 三路 ref_freq 命令
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "2" && cmd_buffer[4] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ21;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "1" && cmd_buffer[4] == "2" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ12;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "1" && cmd_buffer[4] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ11;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            // ★ 通道3 4 路 IIR 阶数 (各路独立, 1..4 = 6/12/18/24 dB/oct)
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "R" && cmd_buffer[2] == "D" && cmd_buffer[3] == "2" && cmd_buffer[4] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_ORD21;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "R" && cmd_buffer[2] == "D" && cmd_buffer[3] == "1" && cmd_buffer[4] == "2" && rec_data == ":") begin
                                cmd_type <= CMD_ORD12;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "R" && cmd_buffer[2] == "D" && cmd_buffer[3] == "1" && cmd_buffer[4] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_ORD11;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "R" && cmd_buffer[2] == "D" && cmd_buffer[3] == "D" && cmd_buffer[4] == "C" && rec_data == ":") begin
                                cmd_type <= CMD_ORDDC;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else begin
                                cmd_cnt <= cmd_cnt + 1'b1;
                            end
                        end
                        // cmd_cnt == 4'd6 分支已删除:
                        //   旧的 6 字符 TAU21X/Y / TAU12X/Y / TAU11X/Y 命令被合并为
                        //   5 字符的 TAU21 / TAU12 / TAU11 (见 cmd_cnt==5 分支),
                        //   因为 X/Y 共用同一个时间常数 (与商用 SR830 等一致).
                        //   到这里 cmd_cnt==6 时会落到末尾的 fall-through (cmd_cnt + 1),
                        //   流程继续推进到 7 (LOCKSWY/LOCKTHX/REFMODE).
                        else if (cmd_cnt == 4'd7) begin
                            // 8 ?????????: LOCKSWY: / LOCKTHX: / REFMODE:
                            if (cmd_buffer[0] == "L" && cmd_buffer[1] == "O" && cmd_buffer[2] == "C" && cmd_buffer[3] == "K"
                             && cmd_buffer[4] == "S" && cmd_buffer[5] == "W" && cmd_buffer[6] == "Y" && rec_data == ":") begin
                                cmd_type <= CMD_LOCKSWY;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "L" && cmd_buffer[1] == "O" && cmd_buffer[2] == "C" && cmd_buffer[3] == "K"
                                  && cmd_buffer[4] == "T" && cmd_buffer[5] == "H" && cmd_buffer[6] == "X" && rec_data == ":") begin
                                cmd_type <= CMD_LOCKTHX;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            // ★ 通道3 ref_freq 来源选择 (REFMODE:0 / REFMODE:1)
                            else if (cmd_buffer[0] == "R" && cmd_buffer[1] == "E" && cmd_buffer[2] == "F" && cmd_buffer[3] == "M"
                                  && cmd_buffer[4] == "O" && cmd_buffer[5] == "D" && cmd_buffer[6] == "E" && rec_data == ":") begin
                                cmd_type <= CMD_REFMODE;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else begin
                                cmd_cnt <= cmd_cnt + 1'b1;
                            end
                        end
                        else if (rec_data == "\r" || rec_data == "\n") begin
                            cmd_type <= 6'd0;
                            curr_state <= SEND_RESPONSE;
                            msg_cnt <= 5'd0;
                            msg_len <= 5'd16;  
                        end
                        else if (cmd_cnt >= 4'd8) begin
                            cmd_type <= 6'd0;
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
                            else if (cmd_type == CMD_TAU1X) begin
                                tau1_x <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_TAU1Y) begin
                                tau1_y <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_TAU2X) begin
                                tau2_x <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_TAU2Y) begin
                                tau2_y <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_TAU21) begin
                                tau21 <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_TAU12) begin
                                tau12 <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_TAU11) begin
                                tau11 <= value_buffer[4:0];
                            end
                            else if (cmd_type == CMD_TAUDC) begin
                                tau_dc <= value_buffer[4:0];
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
                            else if (cmd_type == CMD_FRQ21) begin
                                freq_word_21 <= value_buffer;
                            end
                            else if (cmd_type == CMD_FRQ12) begin
                                freq_word_12 <= value_buffer;
                            end
                            else if (cmd_type == CMD_FRQ11) begin
                                freq_word_11 <= value_buffer;
                            end
                            else if (cmd_type == CMD_LOCKSWY) begin
                                sweep_thres <= value_buffer[27:0];
                            end
                            else if (cmd_type == CMD_LOCKTHX) begin
                                lock_x_thres <= value_buffer[27:0];
                            end
                            else if (cmd_type == CMD_REFMODE) begin
                                ref_freq_auto <= value_buffer[0];   // 只取 bit0: 0=手动, 1=自动
                            end
                            // ★ 4 路独立阶数, 范围钳位到 1..4 (非法值一律视为 1 阶)
                            else if (cmd_type == CMD_ORD21) begin
                                if (value_buffer[3:0] >= 4'd1 && value_buffer[3:0] <= 4'd4)
                                    order21 <= value_buffer[2:0];
                                else
                                    order21 <= 3'd1;
                            end
                            else if (cmd_type == CMD_ORD12) begin
                                if (value_buffer[3:0] >= 4'd1 && value_buffer[3:0] <= 4'd4)
                                    order12 <= value_buffer[2:0];
                                else
                                    order12 <= 3'd1;
                            end
                            else if (cmd_type == CMD_ORD11) begin
                                if (value_buffer[3:0] >= 4'd1 && value_buffer[3:0] <= 4'd4)
                                    order11 <= value_buffer[2:0];
                                else
                                    order11 <= 3'd1;
                            end
                            else if (cmd_type == CMD_ORDDC) begin
                                if (value_buffer[3:0] >= 4'd1 && value_buffer[3:0] <= 4'd4)
                                    order_dc <= value_buffer[2:0];
                                else
                                    order_dc <= 3'd1;
                            end
                            // ★ 信号发生器 (DAC904)
                            else if (cmd_type == CMD_DMOD) begin
                                dac_src_mode <= value_buffer[1:0];
                            end
                            else if (cmd_type == CMD_DFRQ) begin
                                dac_freq_word <= value_buffer;
                            end
                            else if (cmd_type == CMD_DPHS) begin
                                dac_phase_word <= value_buffer;
                            end
                            // ★ 振荡器谐波系数 (n,m 各 0..255)
                            else if (cmd_type == CMD_OSC1) begin
                                osc1_n <= value_buffer[15:8];
                                osc1_m <= value_buffer[7:0];
                            end
                            else if (cmd_type == CMD_OSC2) begin
                                osc2_n <= value_buffer[15:8];
                                osc2_m <= value_buffer[7:0];
                            end
                            else if (cmd_type == CMD_OSC3) begin
                                osc3_n <= value_buffer[15:8];
                                osc3_m <= value_buffer[7:0];
                            end
                            else if (cmd_type == CMD_OSRC1) begin
                                if (value_buffer[1:0] <= 2'd2)
                                    osc1_src <= value_buffer[1:0];
                            end
                            else if (cmd_type == CMD_OSRC2) begin
                                if (value_buffer[1:0] <= 2'd2)
                                    osc2_src <= value_buffer[1:0];
                            end
                            else if (cmd_type == CMD_OSRC3) begin
                                if (value_buffer[1:0] <= 2'd2)
                                    osc3_src <= value_buffer[1:0];
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
                            cmd_type <= 6'd0;
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
                        // byte_cnt = 0 -> ??????????(?????0xA5) ?????
                        send_data <= xy_data_reg[831-byte_cnt*8 -: 8];
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
