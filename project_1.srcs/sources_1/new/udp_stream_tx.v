`timescale 1ns / 1ps
// =============================================================================
//  udp_stream_tx.v
//
//  字节流 → UDP 数据报 (125 MHz 域)
//
//  从 FWFT FIFO 取字节攒进本地包缓冲, 满足以下任一条件就发一个 UDP 包:
//    - 已攒满 MAX_PAYLOAD 字节
//    - 缓冲非空且 FIFO 连续 IDLE_CYC 拍无新字节 (一段数据写完)
//  包长精确等于缓冲字节数, 发送期间暂停取数 (字节留在 FIFO 里).
//  上位机按到达顺序拼接各包载荷即可还原原字节流.
// =============================================================================
module udp_stream_tx #(
    parameter [31:0] LOCAL_IP    = {8'd192, 8'd168, 8'd99, 8'd10},
    parameter [15:0] SRC_PORT    = 16'd1234,
    parameter        MAX_PAYLOAD = 1024,       // 2 的幂
    parameter        IDLE_CYC    = 256         // 2 µs @ 125 MHz
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        enable,

    input  wire [7:0]  fifo_dout,
    input  wire        fifo_empty,
    output wire        fifo_rd_en,

    input  wire [31:0] dest_ip,
    input  wire [15:0] dest_port,

    output reg         m_udp_hdr_valid,
    input  wire        m_udp_hdr_ready,
    output wire [5:0]  m_udp_ip_dscp,
    output wire [1:0]  m_udp_ip_ecn,
    output wire [7:0]  m_udp_ip_ttl,
    output wire [31:0] m_udp_ip_source_ip,
    output reg  [31:0] m_udp_ip_dest_ip,
    output wire [15:0] m_udp_source_port,
    output reg  [15:0] m_udp_dest_port,
    output wire [15:0] m_udp_length,
    output wire [15:0] m_udp_checksum,
    output wire [7:0]  m_udp_payload_axis_tdata,
    output wire        m_udp_payload_axis_tvalid,
    input  wire        m_udp_payload_axis_tready,
    output wire        m_udp_payload_axis_tlast,
    output wire        m_udp_payload_axis_tuser,

    output reg         pkt_sent        // 每发出一个包头 1 拍
);

    localparam AW = $clog2(MAX_PAYLOAD);

    localparam S_FILL = 2'd0,
               S_HDR  = 2'd1,
               S_DATA = 2'd2;

    reg [1:0]  state;
    reg [AW:0] buf_cnt;          // 已攒字节数 (0..MAX_PAYLOAD)
    reg [AW:0] pkt_len;
    reg [AW:0] rd_ptr;
    reg [8:0]  idle_cnt;

    (* ram_style = "distributed" *) reg [7:0] pkt_buf [0:MAX_PAYLOAD-1];

    wire flush = (buf_cnt == MAX_PAYLOAD)
              || ((buf_cnt != 0) && (idle_cnt >= IDLE_CYC));

    assign fifo_rd_en = (state == S_FILL) && enable && !flush && !fifo_empty;

    always @(posedge clk) begin
        if (fifo_rd_en)
            pkt_buf[buf_cnt[AW-1:0]] <= fifo_dout;
    end

    wire data_fire = (state == S_DATA) && m_udp_payload_axis_tready;

    assign m_udp_ip_dscp      = 6'd0;
    assign m_udp_ip_ecn       = 2'd0;
    assign m_udp_ip_ttl       = 8'd64;
    assign m_udp_ip_source_ip = LOCAL_IP;
    assign m_udp_source_port  = SRC_PORT;
    assign m_udp_length       = 16'd8 + pkt_len;
    assign m_udp_checksum     = 16'd0;

    assign m_udp_payload_axis_tdata  = pkt_buf[rd_ptr[AW-1:0]];
    assign m_udp_payload_axis_tvalid = (state == S_DATA);
    assign m_udp_payload_axis_tlast  = (rd_ptr == pkt_len - 1'b1);
    assign m_udp_payload_axis_tuser  = 1'b0;

    always @(posedge clk) begin
        pkt_sent <= 1'b0;
        if (rst) begin
            state           <= S_FILL;
            buf_cnt         <= 0;
            pkt_len         <= 0;
            rd_ptr          <= 0;
            idle_cnt        <= 0;
            m_udp_hdr_valid <= 1'b0;
            m_udp_ip_dest_ip<= 32'd0;
            m_udp_dest_port <= 16'd0;
        end else begin
            case (state)
                S_FILL: begin
                    if (fifo_rd_en) begin
                        buf_cnt  <= buf_cnt + 1'b1;
                        idle_cnt <= 0;
                    end else if (buf_cnt != 0 && idle_cnt != 9'h1FF) begin
                        idle_cnt <= idle_cnt + 1'b1;
                    end
                    if (flush && enable) begin
                        pkt_len          <= buf_cnt;
                        m_udp_ip_dest_ip <= dest_ip;
                        m_udp_dest_port  <= dest_port;
                        m_udp_hdr_valid  <= 1'b1;
                        pkt_sent         <= 1'b1;
                        state            <= S_HDR;
                    end
                end

                S_HDR: begin
                    if (m_udp_hdr_ready) begin
                        m_udp_hdr_valid <= 1'b0;
                        rd_ptr          <= 0;
                        state           <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (data_fire) begin
                        if (m_udp_payload_axis_tlast) begin
                            buf_cnt  <= 0;
                            idle_cnt <= 0;
                            state    <= S_FILL;
                        end else begin
                            rd_ptr <= rd_ptr + 1'b1;
                        end
                    end
                end

                default: state <= S_FILL;
            endcase
        end
    end

endmodule
