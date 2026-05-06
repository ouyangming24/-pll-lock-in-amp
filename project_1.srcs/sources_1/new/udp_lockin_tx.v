`timescale 1ns / 1ps
// =============================================================================
//  udp_lockin_tx.v
//
//  锁相帧 → UDP 发送适配器 (对接 alexforencich/verilog-ethernet 的 udp_complete)
//
//  功能:
//      1) 接收 640 bit (80 字节) 的锁相数据帧 + 单脉冲 trigger
//      2) 把 640 bit 帧串行化成 80 拍 8 bit AXI-Stream payload
//      3) 同步生成 udp_complete 需要的 UDP 包头握手信号:
//           - source/dest IP, source/dest port, UDP length, checksum, TTL, DSCP, ECN
//      4) (Eth 头/IP 头由 udp_complete 内部自动构造, 这里不再输出)
//
//  时钟:
//      工作在 125 MHz, 与 udp_complete 同域.
//
//  数据序: 网络字节序 (大端)
//      tdata[0]  = packed_frame[639:632]   ← 同步头 0xA5
//      tdata[1]  = packed_frame[631:624]
//      ...
//      tdata[79] = packed_frame[7:0]       ← lock_flags 低字节
// =============================================================================
module udp_lockin_tx #(
    parameter [31:0] LOCAL_IP    = {8'd192, 8'd168, 8'd1, 8'd10},
    parameter [31:0] DEST_IP     = {8'd192, 8'd168, 8'd1, 8'd100},
    parameter [15:0] SRC_PORT    = 16'd1234,
    parameter [15:0] DEST_PORT   = 16'd7777,
    parameter [7:0]  IP_TTL      = 8'd64,
    parameter        FRAME_BYTES = 80
)(
    input  wire                              clk,
    input  wire                              rst,

    // 来自跨时钟 FIFO 的并行帧 + 1 拍脉冲
    input  wire [FRAME_BYTES*8-1:0]          frame_data,
    input  wire                              frame_valid,

    // === udp_complete s_udp_* 输入侧 ===
    output reg                               m_udp_hdr_valid,
    input  wire                              m_udp_hdr_ready,
    output wire [5:0]                        m_udp_ip_dscp,
    output wire [1:0]                        m_udp_ip_ecn,
    output wire [7:0]                        m_udp_ip_ttl,
    output wire [31:0]                       m_udp_ip_source_ip,
    output wire [31:0]                       m_udp_ip_dest_ip,
    output wire [15:0]                       m_udp_source_port,
    output wire [15:0]                       m_udp_dest_port,
    output wire [15:0]                       m_udp_length,
    output wire [15:0]                       m_udp_checksum,

    output reg  [7:0]                        m_udp_payload_axis_tdata,
    output reg                               m_udp_payload_axis_tvalid,
    input  wire                              m_udp_payload_axis_tready,
    output reg                               m_udp_payload_axis_tlast,
    output wire                              m_udp_payload_axis_tuser,

    output wire                              busy,
    output reg                               frame_dropped
);

    // ---- 静态包头字段 ----
    assign m_udp_ip_dscp        = 6'd0;
    assign m_udp_ip_ecn         = 2'd0;
    assign m_udp_ip_ttl         = IP_TTL;
    assign m_udp_ip_source_ip   = LOCAL_IP;
    assign m_udp_ip_dest_ip     = DEST_IP;
    assign m_udp_source_port    = SRC_PORT;
    assign m_udp_dest_port      = DEST_PORT;
    assign m_udp_length         = 16'd8 + FRAME_BYTES;   // UDP 长度 = 头8 + 载荷
    assign m_udp_checksum       = 16'd0;                 // 0 = 不校验 (IPv4 允许)
    assign m_udp_payload_axis_tuser = 1'b0;

    // ---- 状态机 ----
    localparam S_IDLE = 2'd0;
    localparam S_HDR  = 2'd1;
    localparam S_DATA = 2'd2;

    reg [1:0]                       state;
    reg [FRAME_BYTES*8-1:0]         shift_reg;
    reg [$clog2(FRAME_BYTES+1)-1:0] byte_cnt;

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state                     <= S_IDLE;
            m_udp_hdr_valid           <= 1'b0;
            m_udp_payload_axis_tvalid <= 1'b0;
            m_udp_payload_axis_tlast  <= 1'b0;
            m_udp_payload_axis_tdata  <= 8'd0;
            shift_reg                 <= {FRAME_BYTES*8{1'b0}};
            byte_cnt                  <= 0;
            frame_dropped             <= 1'b0;
        end else begin
            frame_dropped <= 1'b0;

            case (state)
            S_IDLE: begin
                m_udp_payload_axis_tvalid <= 1'b0;
                m_udp_payload_axis_tlast  <= 1'b0;
                if (frame_valid) begin
                    shift_reg       <= frame_data;
                    m_udp_hdr_valid <= 1'b1;
                    byte_cnt        <= 0;
                    state           <= S_HDR;
                end
            end

            S_HDR: begin
                if (m_udp_hdr_ready) begin
                    m_udp_hdr_valid           <= 1'b0;
                    m_udp_payload_axis_tdata  <= shift_reg[FRAME_BYTES*8-1 -: 8];
                    m_udp_payload_axis_tvalid <= 1'b1;
                    m_udp_payload_axis_tlast  <= (FRAME_BYTES == 1);
                    state                     <= S_DATA;
                end
            end

            S_DATA: begin
                if (m_udp_payload_axis_tvalid && m_udp_payload_axis_tready) begin
                    if (m_udp_payload_axis_tlast) begin
                        m_udp_payload_axis_tvalid <= 1'b0;
                        m_udp_payload_axis_tlast  <= 1'b0;
                        state                     <= S_IDLE;
                    end else begin
                        shift_reg                 <= {shift_reg[FRAME_BYTES*8-9:0], 8'd0};
                        m_udp_payload_axis_tdata  <= shift_reg[FRAME_BYTES*8-9 -: 8];
                        byte_cnt                  <= byte_cnt + 1'b1;
                        m_udp_payload_axis_tlast  <= (byte_cnt == FRAME_BYTES-2);
                    end
                end
                if (frame_valid) frame_dropped <= 1'b1;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
