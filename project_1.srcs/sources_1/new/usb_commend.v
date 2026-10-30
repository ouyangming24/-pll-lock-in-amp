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
//      XYOUT             经典数据流 (GUI, 178 字节全量帧)
//      SDKOUT            SDK 精简流: 振荡器1 + V3/V4/V5 每帧一包 (28 字节), 不攒 1024 点
//      stop              停止任一数据流
//      BAUD:<n>          切换串口波特率 (应答仍用旧波特率发出, 随后切换)
//                        允许: 9600/19200/38400/57600/115200/230400/460800/921600
//                        上电默认 115200; 同时停流
//      RNG3:<c> / RNG4:<c>  AD7606C V3/V4 量程码 (写寄存器 0x04)
//                        c: 0=±2.5 1=±5 2=±6.25 3=±10 4=±12.5 V 单端;
//                           5..7 单极 0~5/10/12.5; 8..11 差分 ±5/10/12.5/20
//                        上电默认 3 (±10 V)
//
//  数据帧 (v2, 178 字节, 大端) — XYOUT:
//      [0..171]   x_y_fir 快照 (同步头 + 测量字段 + sample_cnt, 见 lock_in_amp.v)
//      [172..175] frame_seq  uint32  锁存一帧快照 +1
//      [176..177] CRC16      CRC-16/CCITT-FALSE, 覆盖 [0..175]
//  详见 docs/帧协议v2_时间戳与CRC.md
//
//  SDK 精简帧 (28 字节, 大端) — SDKOUT:
//      [0..3]   0xA5_5A_C3_01  同步头 (与经典帧 / 示波器包区分)
//      [4..7]   osc1_x int32   [8..11] osc1_y int32
//      [12..13] V3 int16       [14..15] V4 int16  [16..17] V5 int16  (AD7606C 原始码)
//      [18..21] sample_cnt uint32
//      [22..25] frame_seq  uint32
//      [26..27] CRC16 (覆盖 [0..25])
//  锁存节拍: ADC conv_done (约 1 MHz 刷新快照); 串口实际发出约 2 k 帧/s (带宽受限)
//
//  示波器 (scope_cap, AD7606C V5/V6) — 仅 XYOUT/空闲时上传; SDKOUT 模式下丢弃抓取结果:
//      SDEC / STLV / SCAP … 1024 点整包 (同步头 A5 5A 5A A5), 详见 handbook
// =============================================================================
module usb_commend #(
    parameter SCOPE_AW  = 10,          // 与 scope_cap.AW 一致
    parameter SCOPE_PRE = 128,         // 与 scope_cap.PRE 一致
    parameter [15:0] BAUD_DIV_DEFAULT = 16'd564  // 65e6/115200 ≈ 564
)(
    input wire clk,
    input wire rst_n,
    input wire [7:0] rec_data,
    input wire rec_done,
    input wire tx_done,
    input wire tx_busy,            // ft245_tx 非空闲 (含等待总线/TXE#); 空闲时才发起新字节
    output wire rx_ready,          // 本模块能处理 rec_done 的状态; 为 0 时 ft245_rx 暂不读, 字节留在 FT245 FIFO
    input wire rx_pending,         // FT245 有待读命令字节: IDLE 时先收命令, 不开新帧
    input wire [1375:0] x_y_fir,   // 172 字节快照 (含 sample_cnt); 本模块追加 frame_seq + CRC16 → 178 字节
    input wire [175:0]  sdk_fir,   // 22 字节: sync+osc1_x/y+V3/V4/V5+sample_cnt; 再追加 seq → 26B +CRC
    input wire          sdk_smp_valid, // ADC 转换完成脉冲 (SDKOUT 锁存用)
    input wire m_axis_data_tvalid_fir_x,
    output reg [15:0] uart_baud_div, // → uart_link: 每比特时钟数
    // AD7606C V3/V4 量程 → 寄存器 0x04 {V4[7:4], V3[3:0]}, we 一拍
    output reg [7:0]  adc_range34,
    output reg        adc_range34_we,
    output reg [47:0] center_freq,
    output reg [15:0] pll_kp,
    output reg [15:0] pll_ki,
    output reg [4:0]  tau1_x,
    output reg [4:0]  tau1_y,
    output reg [4:0]  tau2_x,
    output reg [4:0]  tau2_y,
    //  ? 通道3 三路谐波 IIR 时间常数 (X/Y 共用, 与商 ? SR830  ? ?)
    output reg [4:0]  tau21,    // ch3 @ 2F1+F2
    output reg [4:0]  tau12,    // ch3 @ F1+2F2
    output reg [4:0]  tau11,    // ch3 @ F1+F2
    output reg [4:0]  tau4,     // 振荡 ?4
    output reg [4:0]  tau5,     // 振荡 ?5
    output reg [4:0]  tau6,     // 振荡 ?6
    output reg [4:0]  tau7,     // 振荡器7
    output reg [4:0]  tau_dc,   // ch3 DC 通路 (本来就是单一 IIR)
    output reg [47:0] phase_offset,
    output reg [47:0] freq_word_2,
    output reg [47:0] freq_word_3,
    //  ? 通道3 三路 ?环锁相放大器的参考频 ? (PLL 注释期间可手动下 ?, 平时可由 PLL 输出运算得到)
    output reg [47:0] freq_word_21,           // ch3 @ 2F1+F2 ref_freq (FRQ21)
    output reg [47:0] freq_word_12,           // ch3 @ F1+2F2 ref_freq (FRQ12)
    output reg [47:0] freq_word_11,           // ch3 @ F1+F2  ref_freq (FRQ11)
    output reg [47:0] freq_word_4,            // 振荡 ?4 (FRQ4)
    output reg [47:0] freq_word_5,            // 振荡 ?5 (FRQ5)
    output reg [47:0] freq_word_6,            // 振荡 ?6 (FRQ6)
    output reg [47:0] freq_word_7,            // 振荡器7 (FRQ7)
    output reg signed [27:0] sweep_thres,    // ???PLL Y ??LOCK ????? (LOCKSWY)
    output reg signed [27:0] lock_x_thres,   // ???PLL X ???? LOCK ????? (LOCKTHX)
    //  ? 通道3 三路 ref_freq 来源选择 (REFMODE 命令下发)
    //   0 = 手动 ( ? FRQ21/FRQ12/FRQ11 三个 ?, 默认)
    //   1 = 自动 (硬件实时: n*pll_freq_ch1 + m*pll_freq_ch2, 系数 ? OSC1/2/3 下发)
    output reg ref_freq_auto,
    //  ? 通道3 三路振荡器谐波系 ? (OSC1/OSC2/OSC3 命令, 值打 ?: [15:8]=n, [7:0]=m)
    output reg [7:0] osc1_n, osc1_m,
    output reg [7:0] osc2_n, osc2_m,
    output reg [7:0] osc3_n, osc3_m,
    output reg [7:0] osc4_n, osc4_m,
    output reg [7:0] osc5_n, osc5_m,
    output reg [7:0] osc6_n, osc6_m,
    output reg [7:0] osc7_n, osc7_m,
    //  ? 振荡 ? ADC 输入 ? (OSRC1..6: 0=CH3, 1=CH4, 2=CH3-CH4 差分)
    output reg [1:0] osc1_src,
    output reg [1:0] osc2_src,
    output reg [1:0] osc3_src,
    output reg [1:0] osc4_src,
    output reg [1:0] osc5_src,
    output reg [1:0] osc6_src,
    output reg [1:0] osc7_src,
    //  ? 振荡器谐波阶 ? N (OHN1..6, 默认 1;  ? ? f_ref = f_base × N)
    output reg [7:0] osc1_oh,
    output reg [7:0] osc2_oh,
    output reg [7:0] osc3_oh,
    output reg [7:0] osc4_oh,
    output reg [7:0] osc5_oh,
    output reg [7:0] osc6_oh,
    output reg [7:0] osc7_oh,
    //  ? IIR 阶数 (OSC1..6 + DC, ORD* 命令)
    output reg [2:0] order21,
    output reg [2:0] order12,
    output reg [2:0] order11,
    output reg [2:0] order4,
    output reg [2:0] order5,
    output reg [2:0] order6,
    output reg [2:0] order7,
    output reg [2:0] order_dc,
    //  ? 信号发生 ? (DAC904): dac_src_mode 0..6 = 振荡器1..7
    output reg [2:0]         dac_src_mode,    // DMOD 命令
    output reg [15:0]        dac_amp,         // DAMP: 幅度 16bit, 65535=满幅
    output reg signed [13:0] dac_ofs,         // DOFS: 偏置 (DAC 有符号码)
    output reg               dac_wave_sel,    // DWAV: 0=正弦, 1=方波 (所选振荡器本振的符号)
    // 示波器抓取 (scope_cap)
    output reg                 scope_arm,       // SCAP 收完一拍
    output reg  [3:0]          scope_mode,      // [2:0] 触发模式, [3] 正常模式
    output reg  [15:0]         scope_level,     // 补码
    output reg  [15:0]         scope_decim,
    input  wire                scope_done,
    output reg                 scope_clear,     // 上传完一拍
    input  wire                scope_forced,
    input  wire [2:0]          scope_cap_mode,
    input  wire [15:0]         scope_cap_decim,
    output wire [SCOPE_AW-1:0] scope_rd_idx,
    input  wire [31:0]         scope_rd_data,   // 读延迟 2 拍
    output reg send_en,
    output reg [7:0] send_data
);

    // 波特率 → 分频 (65 MHz); 非法返回 0
    function automatic [15:0] baud_to_div;
        input [23:0] b;
        begin
            case (b)
                24'd9600:   baud_to_div = 16'd6771;
                24'd19200:  baud_to_div = 16'd3385;
                24'd38400:  baud_to_div = 16'd1693;
                24'd57600:  baud_to_div = 16'd1128;
                24'd115200: baud_to_div = 16'd564;
                24'd230400: baud_to_div = 16'd282;
                24'd460800: baud_to_div = 16'd141;
                24'd921600: baud_to_div = 16'd70;
                default:    baud_to_div = 16'd0;
            endcase
        end
    endfunction

    parameter IDLE = 4'd0;
    parameter REC_CMD = 4'd1;
    parameter REC_DATA = 4'd2;
    parameter SEND_RESPONSE = 4'd3;
    parameter WAIT_SEND = 4'd4;
    parameter SEND_XYDATA = 4'd5;
    parameter WAIT_XYDATA = 4'd6;
    parameter WAIT_DELAY = 4'd7;
    parameter SEND_SCOPE = 4'd8;
    parameter WAIT_SCOPE = 4'd9;
    parameter SCOPE_GAP  = 4'd10;   // 等示波器缓存读出 (2 拍延迟)
    parameter SCOPE_END  = 4'd11;   // 等 scope_done 被清, 防止 IDLE 重复上传

    parameter CMD_FREQ    = 7'd1;
    parameter CMD_KP      = 7'd2;
    parameter CMD_KI      = 7'd3;
    parameter CMD_PHAS    = 7'd6;
    parameter CMD_XYOUT   = 7'd7;
    parameter CMD_STOP    = 7'd8;
    parameter CMD_FRQ2    = 7'd9;
    parameter CMD_FRQ3    = 7'd10;
    parameter CMD_LOCKSWY = 7'd11;
    parameter CMD_LOCKTHX = 7'd12;
    parameter CMD_TAU1X   = 7'd13;
    parameter CMD_TAU1Y   = 7'd14;
    parameter CMD_TAU2X   = 7'd15;
    parameter CMD_TAU2Y   = 7'd16;
    parameter CMD_TAU21   = 7'd17;
    parameter CMD_TAU12   = 7'd18;
    parameter CMD_TAU11   = 7'd19;
    parameter CMD_TAUDC   = 7'd20;
    parameter CMD_FRQ21   = 7'd21;
    parameter CMD_FRQ12   = 7'd22;
    parameter CMD_FRQ11   = 7'd23;
    parameter CMD_REFMODE = 7'd24;
    parameter CMD_ORD21   = 7'd25;
    parameter CMD_ORD12   = 7'd26;
    parameter CMD_ORD11   = 7'd27;
    parameter CMD_ORDDC   = 7'd28;
    parameter CMD_DMOD    = 7'd29;
    parameter CMD_DFRQ    = 7'd30;
    parameter CMD_DPHS    = 7'd31;   // 信号发生器内部DDS相位 ? (48bit)
    parameter CMD_OSC1    = 7'd32;   // 振荡 ?1: n*F1+m*F2 系数 ([15:8]=n,[7:0]=m)
    parameter CMD_OSC2    = 7'd33;   // 振荡 ?2
    parameter CMD_OSC3    = 7'd34;   // 振荡 ?3
    parameter CMD_OSRC1   = 7'd35;   // 振荡 ?1 ADC  ?: 0=CH3, 1=CH4, 2=CH3-CH4
    parameter CMD_OSRC2   = 7'd36;
    parameter CMD_OSRC3   = 7'd37;
    parameter CMD_OHN1    = 7'd38;   // 振荡 ?1 谐波阶数 N (f_ref = f_base × N)
    parameter CMD_OHN2    = 7'd39;
    parameter CMD_OHN3    = 7'd40;
    parameter CMD_DAMP    = 7'd41;   // DAC 幅度 (16bit, 65535=满幅)
    parameter CMD_DOFS    = 7'd42;   // DAC 偏置 (14bit signed  ?)
    parameter CMD_OSC4    = 7'd43;
    parameter CMD_OSC5    = 7'd44;
    parameter CMD_OSC6    = 7'd45;
    parameter CMD_OSRC4   = 7'd46;
    parameter CMD_OSRC5   = 7'd47;
    parameter CMD_OSRC6   = 7'd48;
    parameter CMD_OHN4    = 7'd49;
    parameter CMD_OHN5    = 7'd50;
    parameter CMD_OHN6    = 7'd51;
    parameter CMD_TAU4    = 7'd52;
    parameter CMD_TAU5    = 7'd53;
    parameter CMD_TAU6    = 7'd54;
    parameter CMD_FRQ4    = 7'd55;
    parameter CMD_FRQ5    = 7'd56;
    parameter CMD_FRQ6    = 7'd57;
    parameter CMD_ORD4    = 7'd58;
    parameter CMD_ORD5    = 7'd59;
    parameter CMD_ORD6    = 7'd60;
    parameter CMD_OSC7    = 7'd61;
    parameter CMD_OSRC7   = 7'd62;
    parameter CMD_OHN7    = 7'd63;
    parameter CMD_TAU7    = 7'd64;
    parameter CMD_FRQ7    = 7'd65;
    parameter CMD_ORD7    = 7'd66;
    parameter CMD_DWAV    = 7'd67;   // DAC 波形: 0=正弦, 1=方波
    parameter CMD_SCAP    = 7'd68;   // 示波器: 启动一次抓取
    parameter CMD_STLV    = 7'd69;   // 示波器: 触发电平 (偏移码)
    parameter CMD_SDEC    = 7'd70;   // 示波器: 抽取
    parameter CMD_SDKOUT  = 7'd71;   // SDK 精简数据流
    parameter CMD_BAUD    = 7'd72;   // 串口波特率
    parameter CMD_RNG3    = 7'd73;   // V3 量程码
    parameter CMD_RNG4    = 7'd74;   // V4 量程码

    localparam [1:0] STREAM_OFF = 2'd0,
                     STREAM_XY  = 2'd1,   // XYOUT 经典帧
                     STREAM_SDK = 2'd2;   // SDKOUT 精简帧

    reg [3:0] curr_state;
    wire scope_tx = (curr_state == SEND_SCOPE) || (curr_state == WAIT_SCOPE)
                 || (curr_state == SCOPE_GAP)  || (curr_state == SCOPE_END);
    // 发应答 / 示波器包期间 FSM 不处理 rec_done, 此时读出的命令字节会丢失;
    // 拉低 rx_ready 让命令字节留在 FT245 FIFO, 发完再读
    assign rx_ready = (curr_state != SEND_RESPONSE) && (curr_state != WAIT_SEND) && !scope_tx;
    // 发帧中只有非 CR/LF 字节才算新命令开头: 上条命令的 "\n" 在应答期间被暂缓读取,
    // 应答后才读入, 若也打断帧会被当成下一条命令的首字符
    wire rec_cmd_start = rec_done && (rec_data != 8'h0D) && (rec_data != 8'h0A);
    reg [6:0] cmd_type;
    reg [7:0] cmd_buffer[0:9];
    reg [3:0] cmd_cnt;
    reg [47:0] value_buffer;

    reg [1:0] stream_mode;         // STREAM_OFF / STREAM_XY / STREAM_SDK
    reg [1:0] send_mode;           // 进入发送时锁存, 避免发到一半被命令改模式
    reg [7:0] byte_cnt;
    reg [1407:0] xy_data_reg;      // {x_y_fir 快照, frame_seq} = 176 字节
    reg [207:0]  sdk_data_reg;     // {sdk_fir, frame_seq} = 26 字节
    reg new_data_ready;
    reg data_sending;
    reg [31:0] frame_seq;          // 每锁存一帧快照 +1, 上位机据此检测丢帧
    reg [15:0] tx_crc;             // CRC-16/CCITT-FALSE, 随发送逐字节累加
    reg        baud_pending;       // 应答发完后再切换 uart_baud_div
    reg [15:0] baud_div_next;

    // 经典帧 = 176 字节数据 (含同步头) + 2 字节 CRC
    localparam [7:0] DATA_BYTES  = 8'd176;
    localparam [7:0] FRAME_BYTES = 8'd178;
    // SDK 精简帧 = 26 字节数据 + 2 字节 CRC
    localparam [7:0] SDK_DATA_BYTES  = 8'd26;
    localparam [7:0] SDK_FRAME_BYTES = 8'd28;
    localparam [31:0] DELAY_XY  = 32'd19500;  // ~0.3 ms @ 65 MHz
    localparam [31:0] DELAY_SDK = 32'd6500;   // ~0.1 ms, 提高精简帧吞吐

    // 示波器包 = 16 字节包头 + N×4 字节样点 + 2 字节 CRC
    localparam [15:0] SC_N        = 16'd1 << SCOPE_AW;
    localparam [15:0] SC_PRE      = SCOPE_PRE;
    localparam [15:0] SC_DATA_END = 16'd16 + (SC_N << 2);
    localparam [15:0] SC_TOTAL    = SC_DATA_END + 16'd2;

    reg  [15:0] sc_cnt;
    reg  [1:0]  sc_gap;
    reg  [31:0] scope_seq;
    wire [15:0] sc_off = sc_cnt - 16'd16;
    assign scope_rd_idx = sc_off[SCOPE_AW+1:2];
    wire [127:0] sc_hdr = {32'hA5_5A_5A_A5, SC_N, SC_PRE, scope_cap_decim,
                           4'd0, scope_cap_mode, scope_forced, 8'd0, scope_seq};

    // CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, 不反射, 无异或输出
    // (与 Python binascii.crc_hqx(data, 0xFFFF) 一致)
    function [15:0] crc16_ccitt_byte;
        input [15:0] c;
        input [7:0]  d;
        integer k;
        reg [15:0] r;
        begin
            r = c;
            for (k = 7; k >= 0; k = k - 1)
                r = {r[14:0], 1'b0} ^ ((r[15] ^ d[k]) ? 16'h1021 : 16'h0000);
            crc16_ccitt_byte = r;
        end
    endfunction

    reg [31:0] delay_cnt;
    parameter DELAY_1S = 32'd19500; // 保留旧名, 经典帧仍用 DELAY_XY

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
            xy_data_reg    <= 1408'd0;
            sdk_data_reg   <= 208'd0;
            new_data_ready <= 1'b0;
            frame_seq      <= 32'd0;
        end else if (stream_mode == STREAM_SDK && sdk_smp_valid && !data_sending) begin
            // SDKOUT: 每个 ADC 样点刷新快照 (发出速率仍受串口限制)
            sdk_data_reg   <= {sdk_fir, frame_seq};
            frame_seq      <= frame_seq + 32'd1;
            new_data_ready <= 1'b1;
        end else if (stream_mode == STREAM_XY && m_axis_data_tvalid_fir_x_posedge && !data_sending) begin
            xy_data_reg    <= {x_y_fir, frame_seq};
            frame_seq      <= frame_seq + 32'd1;
            new_data_ready <= 1'b1;
        end else if (curr_state == SEND_XYDATA && new_data_ready) begin
            new_data_ready <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
            cmd_type <= 7'd0;
            cmd_cnt <= 4'd0;
            value_buffer <= 48'd0;        
            tx_crc <= 16'hFFFF;
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
            tau4    <= 5'd2;
            tau5    <= 5'd2;
            tau6    <= 5'd2;
            tau7    <= 5'd2;
            tau_dc  <= 5'd2;
            phase_offset <= 48'd0;
            freq_word_2 <= 48'd433038425708 + 48'd433038425;
            //  ? 通道3 三路 ref_freq 默认 ? (对应 F1=50k, F2=60k 时的 2F1+F2 / F1+2F2 / F1+F2)
            freq_word_21 <= 48'd692861481134;   // 160 kHz
            freq_word_12 <= 48'd736165323705;   // 170 kHz
            freq_word_11 <= 48'd476342268280;   // 110 kHz
            freq_word_4  <= 48'd649557638563;   // 150 kHz
            freq_word_5  <= 48'd779469166276;   // 180 kHz
            freq_word_6  <= 48'd952684536559;   // 220 kHz
            freq_word_7  <= 48'd866076851417;   // 200 kHz (4F1)
            ref_freq_auto <= 1'b0;              // 默认手动; GUI 连接后会 ? REFMODE:1
            //  ? 振荡器默认系 ?: 2F1+F2 / F1+2F2 / F1+F2 / 3F1 / 3F2 / 2F1+2F2
            osc1_n <= 8'd2;  osc1_m <= 8'd1;
            osc2_n <= 8'd1;  osc2_m <= 8'd2;
            osc3_n <= 8'd1;  osc3_m <= 8'd1;
            osc4_n <= 8'd3;  osc4_m <= 8'd0;
            osc5_n <= 8'd0;  osc5_m <= 8'd3;
            osc6_n <= 8'd2;  osc6_m <= 8'd2;
            osc7_n <= 8'd4;  osc7_m <= 8'd0;
            osc1_src <= 2'd0;
            osc2_src <= 2'd0;
            osc3_src <= 2'd0;
            osc4_src <= 2'd0;
            osc5_src <= 2'd0;
            osc6_src <= 2'd0;
            osc7_src <= 2'd0;
            osc1_oh  <= 8'd1;
            osc2_oh  <= 8'd1;
            osc3_oh  <= 8'd1;
            osc4_oh  <= 8'd1;
            osc5_oh  <= 8'd1;
            osc6_oh  <= 8'd1;
            osc7_oh  <= 8'd1;
            order21       <= 3'd1;
            order12       <= 3'd1;
            order11       <= 3'd1;
            order4        <= 3'd1;
            order5        <= 3'd1;
            order6        <= 3'd1;
            order7        <= 3'd1;
            order_dc      <= 3'd1;
            dac_src_mode <= 3'd0;
            dac_amp      <= 16'd65535;
            dac_ofs      <= 14'sd0;
            dac_wave_sel <= 1'b0;
            scope_arm    <= 1'b0;
            scope_mode   <= 4'd0;
            scope_level  <= 16'd0;
            scope_decim  <= 16'd0;
            scope_clear  <= 1'b0;
            scope_seq    <= 32'd0;
            sc_cnt       <= 16'd0;
            sc_gap       <= 2'd0;
            // ???PLL ?????????????????(????, ???????????????????
            sweep_thres  <= 28'd100_000;   // |dc_y| > 100K ?????LOCK
            lock_x_thres <= 28'd300_000;   // LOCK ?????? |dc_x| ??> 300K ????

            send_en <= 1'b0;
            send_data <= 8'd0;
            stream_mode <= STREAM_OFF;
            send_mode <= STREAM_OFF;
            byte_cnt <= 8'd0;
            data_sending <= 1'b0;
            delay_cnt <= 32'd0;
            uart_baud_div <= BAUD_DIV_DEFAULT;
            baud_pending  <= 1'b0;
            baud_div_next <= BAUD_DIV_DEFAULT;
            adc_range34   <= 8'h33;  // V3/V4 均 ±10 V
            adc_range34_we<= 1'b0;
        end
        else begin
            scope_arm   <= 1'b0;
            scope_clear <= 1'b0;
            adc_range34_we <= 1'b0;
            case (curr_state)
                IDLE: begin
                    data_sending <= 1'b0;

                    if (rec_done) begin
                        // 只忽略行尾多余 \r/\n。不要忽略 0x00：
                        // 若 FT245 读到全 0，忽略 0x00 会表现为“完全无应答”。
                        if (rec_data == 8'h0D || rec_data == 8'h0A) begin
                            curr_state <= IDLE;
                        end
                        else begin
                            cmd_buffer[0] <= rec_data;
                            cmd_cnt <= 4'd1;
                            curr_state <= REC_CMD;
                        end
                    end
                    else if (scope_done && !rx_pending) begin
                        if (stream_mode == STREAM_SDK) begin
                            // SDKOUT 模式不上传 1024 点包, 直接清掉抓取结果
                            scope_clear <= 1'b1;
                        end else begin
                            curr_state <= SEND_SCOPE;
                            sc_cnt <= 16'd0;
                            tx_crc <= 16'hFFFF;
                            data_sending <= 1'b1;
                        end
                    end
                    else if ((stream_mode != STREAM_OFF) && new_data_ready && !rx_pending) begin
                        curr_state <= SEND_XYDATA;
                        send_mode  <= stream_mode;
                        byte_cnt <= 8'd0;
                        tx_crc <= 16'hFFFF;
                        data_sending <= 1'b1;
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
                                stream_mode <= STREAM_OFF;
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
                                stream_mode <= STREAM_XY;
                                curr_state <= SEND_RESPONSE;
                                msg_cnt <= 5'd0;
                                msg_len <= 5'd18; 
                            end
                            //  ? 信号发生 ? (DAC904): DMOD / DFRQ / DPHS (均为 4 字符命令)
                            else if (cmd_buffer[0] == "B" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "D" && rec_data == ":") begin
                                cmd_type <= CMD_BAUD;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "R" && cmd_buffer[1] == "N" && cmd_buffer[2] == "G" && cmd_buffer[3] == "3" && rec_data == ":") begin
                                cmd_type <= CMD_RNG3;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "R" && cmd_buffer[1] == "N" && cmd_buffer[2] == "G" && cmd_buffer[3] == "4" && rec_data == ":") begin
                                cmd_type <= CMD_RNG4;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
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
                            else if (cmd_buffer[0] == "D" && cmd_buffer[1] == "A" && cmd_buffer[2] == "M" && cmd_buffer[3] == "P" && rec_data == ":") begin
                                cmd_type <= CMD_DAMP;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "D" && cmd_buffer[1] == "O" && cmd_buffer[2] == "F" && cmd_buffer[3] == "S" && rec_data == ":") begin
                                cmd_type <= CMD_DOFS;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "D" && cmd_buffer[1] == "W" && cmd_buffer[2] == "A" && cmd_buffer[3] == "V" && rec_data == ":") begin
                                cmd_type <= CMD_DWAV;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "S" && cmd_buffer[1] == "C" && cmd_buffer[2] == "A" && cmd_buffer[3] == "P" && rec_data == ":") begin
                                cmd_type <= CMD_SCAP; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "S" && cmd_buffer[1] == "T" && cmd_buffer[2] == "L" && cmd_buffer[3] == "V" && rec_data == ":") begin
                                cmd_type <= CMD_STLV; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "S" && cmd_buffer[1] == "D" && cmd_buffer[2] == "E" && cmd_buffer[3] == "C" && rec_data == ":") begin
                                cmd_type <= CMD_SDEC; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            //  ? 通道3 振荡器谐波系 ? OSC1/OSC2/OSC3 ( ?=[15:8]n,[7:0]m)
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
                            //  ? 振荡器谐波阶 ? OHN1/2/3 (N ?1, 0 视为 1)
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "H" && cmd_buffer[2] == "N" && cmd_buffer[3] == "1" && rec_data == ":") begin
                                cmd_type <= CMD_OHN1;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "H" && cmd_buffer[2] == "N" && cmd_buffer[3] == "2" && rec_data == ":") begin
                                cmd_type <= CMD_OHN2;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "H" && cmd_buffer[2] == "N" && cmd_buffer[3] == "3" && rec_data == ":") begin
                                cmd_type <= CMD_OHN3;
                                value_buffer <= 48'd0;
                                curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "C" && cmd_buffer[3] == "4" && rec_data == ":") begin
                                cmd_type <= CMD_OSC4; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "C" && cmd_buffer[3] == "5" && rec_data == ":") begin
                                cmd_type <= CMD_OSC5; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "C" && cmd_buffer[3] == "6" && rec_data == ":") begin
                                cmd_type <= CMD_OSC6; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "H" && cmd_buffer[2] == "N" && cmd_buffer[3] == "4" && rec_data == ":") begin
                                cmd_type <= CMD_OHN4; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "H" && cmd_buffer[2] == "N" && cmd_buffer[3] == "5" && rec_data == ":") begin
                                cmd_type <= CMD_OHN5; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "H" && cmd_buffer[2] == "N" && cmd_buffer[3] == "6" && rec_data == ":") begin
                                cmd_type <= CMD_OHN6; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "4" && rec_data == ":") begin
                                cmd_type <= CMD_TAU4; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "5" && rec_data == ":") begin
                                cmd_type <= CMD_TAU5; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "6" && rec_data == ":") begin
                                cmd_type <= CMD_TAU6; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "4" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ4; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "5" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ5; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "6" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ6; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "R" && cmd_buffer[2] == "D" && cmd_buffer[3] == "4" && rec_data == ":") begin
                                cmd_type <= CMD_ORD4; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "R" && cmd_buffer[2] == "D" && cmd_buffer[3] == "5" && rec_data == ":") begin
                                cmd_type <= CMD_ORD5; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "R" && cmd_buffer[2] == "D" && cmd_buffer[3] == "6" && rec_data == ":") begin
                                cmd_type <= CMD_ORD6; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "C" && cmd_buffer[3] == "7" && rec_data == ":") begin
                                cmd_type <= CMD_OSC7; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "H" && cmd_buffer[2] == "N" && cmd_buffer[3] == "7" && rec_data == ":") begin
                                cmd_type <= CMD_OHN7; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "7" && rec_data == ":") begin
                                cmd_type <= CMD_TAU7; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "F" && cmd_buffer[1] == "R" && cmd_buffer[2] == "Q" && cmd_buffer[3] == "7" && rec_data == ":") begin
                                cmd_type <= CMD_FRQ7; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "R" && cmd_buffer[2] == "D" && cmd_buffer[3] == "7" && rec_data == ":") begin
                                cmd_type <= CMD_ORD7; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else begin
                                cmd_cnt <= cmd_cnt + 1'b1;
                            end
                        end
                        else if (cmd_cnt == 4'd5) begin
                            // 6 字符: SDKOUT / TAU1X: ...
                            if (cmd_buffer[0] == "S" && cmd_buffer[1] == "D" && cmd_buffer[2] == "K"
                             && cmd_buffer[3] == "O" && cmd_buffer[4] == "U" && rec_data == "T") begin
                                cmd_type <= CMD_SDKOUT;
                                stream_mode <= STREAM_SDK;
                                curr_state <= SEND_RESPONSE;
                                msg_cnt <= 5'd0;
                                msg_len <= 5'd18;
                            end
                            else if (cmd_buffer[0] == "T" && cmd_buffer[1] == "A" && cmd_buffer[2] == "U" && cmd_buffer[3] == "1" && cmd_buffer[4] == "X" && rec_data == ":") begin
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
                            //  ? 通道3 三路谐波 IIR 时间常数 (X/Y 共用, 商用做法)
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
                            //  ? 振荡 ? ADC 输入 ? OSRC1/2/3 (0=CH3, 1=CH4, 2=CH3-CH4)
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
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "R" && cmd_buffer[3] == "C" && cmd_buffer[4] == "4" && rec_data == ":") begin
                                cmd_type <= CMD_OSRC4; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "R" && cmd_buffer[3] == "C" && cmd_buffer[4] == "5" && rec_data == ":") begin
                                cmd_type <= CMD_OSRC5; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "R" && cmd_buffer[3] == "C" && cmd_buffer[4] == "6" && rec_data == ":") begin
                                cmd_type <= CMD_OSRC6; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            else if (cmd_buffer[0] == "O" && cmd_buffer[1] == "S" && cmd_buffer[2] == "R" && cmd_buffer[3] == "C" && cmd_buffer[4] == "7" && rec_data == ":") begin
                                cmd_type <= CMD_OSRC7; value_buffer <= 48'd0; curr_state <= REC_DATA;
                            end
                            //  ? 通道3 三路 ref_freq 命令
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
                            //  ? 通道3 4  ? IIR 阶数 (各路独立, 1..4 = 6/12/18/24 dB/oct)
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
                        // cmd_cnt == 4'd6 分支已删 ?:
                        //   旧的 6 字符 TAU21X/Y / TAU12X/Y / TAU11X/Y 命令被合并为
                        //   5 字符 ? TAU21 / TAU12 / TAU11 ( ? cmd_cnt==5 分支),
                        //   因为 X/Y 共用同一个时间常 ? (与商 ? SR830 等一 ?).
                        //   到这 ? cmd_cnt==6 时会落到末尾 ? fall-through (cmd_cnt + 1),
                        //   流程继续推进 ? 7 (LOCKSWY/LOCKTHX/REFMODE).
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
                            //  ? 通道3 ref_freq 来源选择 (REFMODE:0 / REFMODE:1)
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
                            cmd_type <= 7'd0;
                            curr_state <= SEND_RESPONSE;
                            msg_cnt <= 5'd0;
                            msg_len <= 5'd16;  
                        end
                        else if (cmd_cnt >= 4'd8) begin
                            cmd_type <= 7'd0;
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
                            //  ? 4 路独立阶 ?, 范围钳位 ? 1..4 (非法值一律视 ? 1  ?)
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
                            //  ? 信号发生 ? (DAC904)
                            else if (cmd_type == CMD_DMOD) begin
                                dac_src_mode <= value_buffer[2:0];
                            end
                            else if (cmd_type == CMD_DFRQ) begin
                                ; // 已废 ?: 频率由所选振荡器决定
                            end
                            else if (cmd_type == CMD_DPHS) begin
                                ; // 已废 ?: 相位由所选振荡器本振决定
                            end
                            else if (cmd_type == CMD_DAMP) begin
                                dac_amp <= value_buffer[15:0];
                            end
                            else if (cmd_type == CMD_DOFS) begin
                                dac_ofs <= $signed(value_buffer[13:0]);
                            end
                            else if (cmd_type == CMD_DWAV) begin
                                dac_wave_sel <= value_buffer[0];
                            end
                            else if (cmd_type == CMD_SCAP) begin
                                scope_mode <= value_buffer[3:0];
                                scope_arm  <= 1'b1;
                            end
                            else if (cmd_type == CMD_STLV) begin
                                scope_level <= {~value_buffer[15], value_buffer[14:0]};
                            end
                            else if (cmd_type == CMD_SDEC) begin
                                scope_decim <= value_buffer[15:0];
                            end
                            else if (cmd_type == CMD_BAUD) begin
                                if (baud_to_div(value_buffer[23:0]) != 16'd0) begin
                                    baud_div_next <= baud_to_div(value_buffer[23:0]);
                                    baud_pending  <= 1'b1;
                                    stream_mode   <= STREAM_OFF;
                                end else begin
                                    cmd_type <= 7'd0;  // Command Error!
                                end
                            end
                            else if (cmd_type == CMD_RNG3) begin
                                if (value_buffer[3:0] <= 4'd11) begin
                                    adc_range34    <= {adc_range34[7:4], value_buffer[3:0]};
                                    adc_range34_we <= 1'b1;
                                end else
                                    cmd_type <= 7'd0;
                            end
                            else if (cmd_type == CMD_RNG4) begin
                                if (value_buffer[3:0] <= 4'd11) begin
                                    adc_range34    <= {value_buffer[3:0], adc_range34[3:0]};
                                    adc_range34_we <= 1'b1;
                                end else
                                    cmd_type <= 7'd0;
                            end
                            //  ? 振荡器谐波系 ? (n,m  ? 0..255)
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
                            else if (cmd_type == CMD_OHN1) begin
                                osc1_oh <= (value_buffer[7:0] == 8'd0) ? 8'd1 : value_buffer[7:0];
                            end
                            else if (cmd_type == CMD_OHN2) begin
                                osc2_oh <= (value_buffer[7:0] == 8'd0) ? 8'd1 : value_buffer[7:0];
                            end
                            else if (cmd_type == CMD_OHN3) begin
                                osc3_oh <= (value_buffer[7:0] == 8'd0) ? 8'd1 : value_buffer[7:0];
                            end
                            else if (cmd_type == CMD_OSC4) begin osc4_n <= value_buffer[15:8]; osc4_m <= value_buffer[7:0]; end
                            else if (cmd_type == CMD_OSC5) begin osc5_n <= value_buffer[15:8]; osc5_m <= value_buffer[7:0]; end
                            else if (cmd_type == CMD_OSC6) begin osc6_n <= value_buffer[15:8]; osc6_m <= value_buffer[7:0]; end
                            else if (cmd_type == CMD_OSRC4) begin if (value_buffer[1:0] <= 2'd2) osc4_src <= value_buffer[1:0]; end
                            else if (cmd_type == CMD_OSRC5) begin if (value_buffer[1:0] <= 2'd2) osc5_src <= value_buffer[1:0]; end
                            else if (cmd_type == CMD_OSRC6) begin if (value_buffer[1:0] <= 2'd2) osc6_src <= value_buffer[1:0]; end
                            else if (cmd_type == CMD_OHN4) begin osc4_oh <= (value_buffer[7:0] == 8'd0) ? 8'd1 : value_buffer[7:0]; end
                            else if (cmd_type == CMD_OHN5) begin osc5_oh <= (value_buffer[7:0] == 8'd0) ? 8'd1 : value_buffer[7:0]; end
                            else if (cmd_type == CMD_OHN6) begin osc6_oh <= (value_buffer[7:0] == 8'd0) ? 8'd1 : value_buffer[7:0]; end
                            else if (cmd_type == CMD_TAU4) begin tau4 <= value_buffer[4:0]; end
                            else if (cmd_type == CMD_TAU5) begin tau5 <= value_buffer[4:0]; end
                            else if (cmd_type == CMD_TAU6) begin tau6 <= value_buffer[4:0]; end
                            else if (cmd_type == CMD_FRQ4) begin freq_word_4 <= value_buffer; end
                            else if (cmd_type == CMD_FRQ5) begin freq_word_5 <= value_buffer; end
                            else if (cmd_type == CMD_FRQ6) begin freq_word_6 <= value_buffer; end
                            else if (cmd_type == CMD_ORD4) begin
                                if (value_buffer[3:0] >= 4'd1 && value_buffer[3:0] <= 4'd4) order4 <= value_buffer[2:0]; else order4 <= 3'd1;
                            end
                            else if (cmd_type == CMD_ORD5) begin
                                if (value_buffer[3:0] >= 4'd1 && value_buffer[3:0] <= 4'd4) order5 <= value_buffer[2:0]; else order5 <= 3'd1;
                            end
                            else if (cmd_type == CMD_ORD6) begin
                                if (value_buffer[3:0] >= 4'd1 && value_buffer[3:0] <= 4'd4) order6 <= value_buffer[2:0]; else order6 <= 3'd1;
                            end
                            else if (cmd_type == CMD_OSC7) begin osc7_n <= value_buffer[15:8]; osc7_m <= value_buffer[7:0]; end
                            else if (cmd_type == CMD_OSRC7) begin if (value_buffer[1:0] <= 2'd2) osc7_src <= value_buffer[1:0]; end
                            else if (cmd_type == CMD_OHN7) begin osc7_oh <= (value_buffer[7:0] == 8'd0) ? 8'd1 : value_buffer[7:0]; end
                            else if (cmd_type == CMD_TAU7) begin tau7 <= value_buffer[4:0]; end
                            else if (cmd_type == CMD_FRQ7) begin freq_word_7 <= value_buffer; end
                            else if (cmd_type == CMD_ORD7) begin
                                if (value_buffer[3:0] >= 4'd1 && value_buffer[3:0] <= 4'd4) order7 <= value_buffer[2:0]; else order7 <= 3'd1;
                            end
                            curr_state <= SEND_RESPONSE;
                            msg_cnt <= 5'd0;
                            // BAUD/RNG 非法时上面把 cmd_type 置 0; 组合条件决定应答长度
                            if ((cmd_type == CMD_BAUD && baud_to_div(value_buffer[23:0]) == 16'd0) ||
                                ((cmd_type == CMD_RNG3 || cmd_type == CMD_RNG4) && value_buffer[3:0] > 4'd11))
                                msg_len <= 5'd16;
                            else
                                msg_len <= 5'd18;
                        end
                    end
                end

                SEND_RESPONSE: begin
                    if (!send_en && !tx_done && !tx_busy) begin
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
                            cmd_type <= 7'd0;
                            value_buffer <= 48'd0;
                            // 应答发完后再切波特率, 保证 Success 走旧速率
                            if (baud_pending) begin
                                uart_baud_div <= baud_div_next;
                                baud_pending  <= 1'b0;
                            end
                        end
                    end
                end

                SEND_XYDATA: begin
                    if (rec_cmd_start) begin
                        cmd_buffer[0] <= rec_data;
                        cmd_cnt <= 4'd1;
                        curr_state <= REC_CMD;
                        data_sending <= 1'b0;
                        byte_cnt <= 8'd0;
                        send_en <= 1'b0;
                    end
                    else if (stream_mode == STREAM_OFF) begin
                        curr_state <= IDLE;
                        data_sending <= 1'b0;
                        byte_cnt <= 8'd0;
                    end
                    else if (!send_en && !tx_done && !tx_busy) begin
                        send_en <= 1'b1;
                        data_sending <= 1'b1;
                        // byte_cnt = 0 -> 最高字节先发; 数据之后发 CRC 高/低字节
                        if (send_mode == STREAM_SDK) begin
                            if (byte_cnt < SDK_DATA_BYTES)
                                send_data <= sdk_data_reg[207-byte_cnt*8 -: 8];
                            else if (byte_cnt == SDK_DATA_BYTES)
                                send_data <= tx_crc[15:8];
                            else
                                send_data <= tx_crc[7:0];
                        end else begin
                            if (byte_cnt < DATA_BYTES)
                                send_data <= xy_data_reg[1407-byte_cnt*8 -: 8];
                            else if (byte_cnt == DATA_BYTES)
                                send_data <= tx_crc[15:8];
                            else
                                send_data <= tx_crc[7:0];
                        end
                        curr_state <= WAIT_XYDATA;
                    end
                end

                WAIT_XYDATA: begin
                    if (rec_cmd_start) begin
                        cmd_buffer[0] <= rec_data;
                        cmd_cnt <= 4'd1;
                        curr_state <= REC_CMD;
                        data_sending <= 1'b0;
                        byte_cnt <= 8'd0;
                        send_en <= 1'b0;
                    end
                    else if (stream_mode == STREAM_OFF) begin
                        curr_state <= IDLE;
                        data_sending <= 1'b0;
                        byte_cnt <= 8'd0;
                        send_en <= 1'b0;  
                    end
                    else if (tx_done) begin
                        send_en <= 1'b0;
                        if (send_mode == STREAM_SDK) begin
                            if (byte_cnt < SDK_DATA_BYTES)
                                tx_crc <= crc16_ccitt_byte(tx_crc, send_data);
                            if (byte_cnt < SDK_FRAME_BYTES - 1) begin
                                byte_cnt <= byte_cnt + 1'b1;
                                curr_state <= SEND_XYDATA;
                            end else begin
                                byte_cnt <= 8'd0;
                                curr_state <= WAIT_DELAY;
                                delay_cnt <= 32'd0;
                                data_sending <= 1'b0;
                            end
                        end else begin
                            if (byte_cnt < DATA_BYTES)
                                tx_crc <= crc16_ccitt_byte(tx_crc, send_data);
                            if (byte_cnt < FRAME_BYTES - 1) begin
                                byte_cnt <= byte_cnt + 1'b1;
                                curr_state <= SEND_XYDATA;
                            end else begin
                                byte_cnt <= 8'd0;
                                curr_state <= WAIT_DELAY;
                                delay_cnt <= 32'd0;
                                data_sending <= 1'b0;
                            end
                        end
                    end
                end

                WAIT_DELAY: begin
                    if (rec_cmd_start) begin
                        cmd_buffer[0] <= rec_data;
                        cmd_cnt <= 4'd1;
                        curr_state <= REC_CMD;
                        delay_cnt <= 32'd0;
                    end
                    else if (stream_mode == STREAM_OFF) begin
                        curr_state <= IDLE;
                        delay_cnt <= 32'd0;
                    end
                    else if (delay_cnt >= ((send_mode == STREAM_SDK) ? DELAY_SDK : DELAY_XY)) begin
                        curr_state <= IDLE;         
                    end else begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end
                end

                // 示波器包: 不被命令打断 (rx_ready=0, 命令字节留在 FT245 FIFO)
                SEND_SCOPE: begin
                    if (!send_en && !tx_done && !tx_busy) begin
                        send_en <= 1'b1;
                        if (sc_cnt < 16'd16)
                            send_data <= sc_hdr[127 - sc_cnt[3:0]*8 -: 8];
                        else if (sc_cnt < SC_DATA_END)
                            case (sc_off[1:0])
                                2'd0: send_data <= scope_rd_data[31:24];
                                2'd1: send_data <= scope_rd_data[23:16];
                                2'd2: send_data <= scope_rd_data[15:8];
                                default: send_data <= scope_rd_data[7:0];
                            endcase
                        else if (sc_cnt == SC_DATA_END)
                            send_data <= tx_crc[15:8];
                        else
                            send_data <= tx_crc[7:0];
                        curr_state <= WAIT_SCOPE;
                    end
                end

                WAIT_SCOPE: begin
                    if (tx_done) begin
                        send_en <= 1'b0;
                        if (sc_cnt < SC_DATA_END)
                            tx_crc <= crc16_ccitt_byte(tx_crc, send_data);
                        if (sc_cnt < SC_TOTAL - 16'd1) begin
                            sc_cnt <= sc_cnt + 16'd1;
                            sc_gap <= 2'd0;
                            curr_state <= SCOPE_GAP;
                        end
                        else begin
                            sc_cnt <= 16'd0;
                            scope_seq <= scope_seq + 32'd1;
                            scope_clear <= 1'b1;
                            curr_state <= SCOPE_END;
                        end
                    end
                end

                SCOPE_GAP: begin
                    if (sc_gap == 2'd3)
                        curr_state <= SEND_SCOPE;
                    else
                        sc_gap <= sc_gap + 2'd1;
                end

                SCOPE_END: begin
                    data_sending <= 1'b0;
                    curr_state <= IDLE;
                end

                default: curr_state <= IDLE;
            endcase
        end
    end

endmodule
