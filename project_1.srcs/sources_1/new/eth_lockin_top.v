`timescale 1ns / 1ps
// =============================================================================
//  eth_lockin_top.v
//
//  以太网 UDP 上行 顶层 (PL 端, 千兆 RGMII PHY)
//
//  数据通路 (按 alexforencich/verilog-ethernet 标准例程拓扑):
//
//      [65 MHz 域]                          [125 MHz 域]
//      x_y_fir_packed (640b) ─┐
//      frame_valid     (1b)   ┴─► XPM_FIFO_ASYNC ─► udp_lockin_tx
//                                 (跨时钟 + 缓冲)         │
//                                                        ▼
//                                               udp_complete (UDP/IP/ARP)
//                                                ▲                │
//                                                │                ▼
//                                       eth_axis_rx          eth_axis_tx
//                                          ▲                       │
//                                          │                       ▼
//                                    rx_axis(8b)              tx_axis(8b)
//                                          ▲                       │
//                                          │                       ▼
//                                    eth_mac_1g_rgmii_fifo (TX/RX FIFO + MAC)
//                                                ▲                │
//                                                │                ▼
//                                            RGMII_RX        RGMII_TX
//                                                │                │
//                                                ▼                ▼
//                                        RTL8211E PHY ──── 网线 ────
// =============================================================================
module eth_lockin_top #(
    parameter [47:0] LOCAL_MAC   = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP    = {8'd192, 8'd168, 8'd1, 8'd10},
    parameter [31:0] DEST_IP     = {8'd192, 8'd168, 8'd1, 8'd100},
    parameter [31:0] GATEWAY_IP  = {8'd192, 8'd168, 8'd1, 8'd1},
    parameter [31:0] SUBNET_MASK = {8'd255, 8'd255, 8'd255, 8'd0},
    parameter [15:0] SRC_PORT    = 16'd1234,
    parameter [15:0] DEST_PORT   = 16'd7777,
    parameter        FRAME_BYTES = 80
)(
    // 基准时钟 / 复位
    input  wire         pl_clk_50m,
    input  wire         sys_rst,       // 高有效

    // 锁相数据接口 (65 MHz 域)
    input  wire         lockin_clk,
    input  wire [FRAME_BYTES*8-1:0] lockin_frame_data,
    input  wire         lockin_frame_valid,

    // RGMII PHY (RTL8211E)
    input  wire         eth_rxc,
    input  wire         eth_rxctl,
    input  wire [3:0]   eth_rxd,
    output wire         eth_txc,
    output wire         eth_txctl,
    output wire [3:0]   eth_txd,
    output wire         eth_nrst,
    output wire         eth_mdc,
    inout  wire         eth_mdio,

    // 状态/调试
    output wire         link_up,
    output wire [1:0]   link_speed,
    output wire         frame_dropped
);

    // -------------------------------------------------------------------------
    // 1) 50 MHz → 125 MHz (0°) + 125 MHz (90°)
    // -------------------------------------------------------------------------
    wire clk125, clk125_90, mmcm_locked;

    clk_wiz_eth u_clk_wiz_eth (
        .clk_in1  (pl_clk_50m),
        .clk_out1 (clk125),
        .clk_out2 (clk125_90),
        .locked   (mmcm_locked),
        .reset    (sys_rst)
    );

    // 125 MHz 同步复位
    reg [3:0] rst125_pipe = 4'b1111;
    wire rst125 = rst125_pipe[3];
    always @(posedge clk125) begin
        if (sys_rst | ~mmcm_locked)
            rst125_pipe <= 4'b1111;
        else
            rst125_pipe <= {rst125_pipe[2:0], 1'b0};
    end

    // -------------------------------------------------------------------------
    // 2) PHY 上电硬复位
    // -------------------------------------------------------------------------
    wire phy_ready;
    eth_phy_init #(
        .CLK_FREQ_HZ      (125_000_000),
        .PHY_RST_LOW_MS   (20),
        .PHY_INIT_WAIT_MS (200)
    ) u_phy_init (
        .clk       (clk125),
        .rst       (rst125),
        .phy_rst_n (eth_nrst),
        .phy_ready (phy_ready)
    );

    assign eth_mdc  = 1'b0;
    assign eth_mdio = 1'bz;

    // -------------------------------------------------------------------------
    // 3) 跨时钟 FIFO: 65 MHz → 125 MHz
    // -------------------------------------------------------------------------
    wire        fifo_full, fifo_empty;
    wire [FRAME_BYTES*8-1:0] fifo_dout;

    reg fifo_rd_en_r;
    wire adapter_busy;
    wire fifo_rd_en = ~fifo_empty & ~adapter_busy & ~fifo_rd_en_r & phy_ready;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE  ("auto"),
        .FIFO_WRITE_DEPTH  (16),
        .WRITE_DATA_WIDTH  (FRAME_BYTES*8),
        .READ_DATA_WIDTH   (FRAME_BYTES*8),
        .READ_MODE         ("std"),
        .USE_ADV_FEATURES  ("0000"),
        .CDC_SYNC_STAGES   (2)
    ) u_frame_cdc_fifo (
        .wr_clk    (lockin_clk),
        .wr_en     (lockin_frame_valid & ~fifo_full),
        .din       (lockin_frame_data),
        .full      (fifo_full),
        .rd_clk    (clk125),
        .rd_en     (fifo_rd_en),
        .dout      (fifo_dout),
        .empty     (fifo_empty),
        .wr_data_count(), .rd_data_count(),
        .almost_empty(), .almost_full(), .data_valid(),
        .dbiterr(), .overflow(), .prog_empty(), .prog_full(),
        .rd_rst_busy(), .sbiterr(), .underflow(), .wr_ack(), .wr_rst_busy(),
        .injectdbiterr(1'b0), .injectsbiterr(1'b0),
        .rst       (rst125),
        .sleep     (1'b0)
    );

    always @(posedge clk125) begin
        if (rst125) fifo_rd_en_r <= 1'b0;
        else        fifo_rd_en_r <= fifo_rd_en;
    end

    // -------------------------------------------------------------------------
    // 4) UDP 适配器
    // -------------------------------------------------------------------------
    wire        udp_hdr_valid, udp_hdr_ready;
    wire [5:0]  udp_ip_dscp;
    wire [1:0]  udp_ip_ecn;
    wire [7:0]  udp_ip_ttl;
    wire [31:0] udp_ip_source_ip, udp_ip_dest_ip;
    wire [15:0] udp_source_port, udp_dest_port, udp_length, udp_checksum;
    wire [7:0]  udp_payload_tdata;
    wire        udp_payload_tvalid, udp_payload_tready, udp_payload_tlast, udp_payload_tuser;

    udp_lockin_tx #(
        .LOCAL_IP    (LOCAL_IP),
        .DEST_IP     (DEST_IP),
        .SRC_PORT    (SRC_PORT),
        .DEST_PORT   (DEST_PORT),
        .FRAME_BYTES (FRAME_BYTES)
    ) u_udp_tx (
        .clk          (clk125),
        .rst          (rst125),
        .frame_data   (fifo_dout),
        .frame_valid  (fifo_rd_en_r),
        .m_udp_hdr_valid           (udp_hdr_valid),
        .m_udp_hdr_ready           (udp_hdr_ready),
        .m_udp_ip_dscp             (udp_ip_dscp),
        .m_udp_ip_ecn              (udp_ip_ecn),
        .m_udp_ip_ttl              (udp_ip_ttl),
        .m_udp_ip_source_ip        (udp_ip_source_ip),
        .m_udp_ip_dest_ip          (udp_ip_dest_ip),
        .m_udp_source_port         (udp_source_port),
        .m_udp_dest_port           (udp_dest_port),
        .m_udp_length              (udp_length),
        .m_udp_checksum            (udp_checksum),
        .m_udp_payload_axis_tdata  (udp_payload_tdata),
        .m_udp_payload_axis_tvalid (udp_payload_tvalid),
        .m_udp_payload_axis_tready (udp_payload_tready),
        .m_udp_payload_axis_tlast  (udp_payload_tlast),
        .m_udp_payload_axis_tuser  (udp_payload_tuser),
        .busy           (adapter_busy),
        .frame_dropped  (frame_dropped)
    );

    // -------------------------------------------------------------------------
    // 5) 8-bit AXIS 总线 (MAC ↔ eth_axis_rx/tx)
    // -------------------------------------------------------------------------
    wire [7:0]  rx_axis_tdata,  tx_axis_tdata;
    wire        rx_axis_tvalid, tx_axis_tvalid;
    wire        rx_axis_tready, tx_axis_tready;
    wire        rx_axis_tlast,  tx_axis_tlast;
    wire        rx_axis_tuser,  tx_axis_tuser;

    // -------------------------------------------------------------------------
    // 6) Ethernet frame 总线 (eth_axis_rx/tx ↔ udp_complete)
    // -------------------------------------------------------------------------
    // RX: MAC → eth_axis_rx → udp_complete.s_eth_*
    wire        rx_eth_hdr_valid, rx_eth_hdr_ready;
    wire [47:0] rx_eth_dest_mac, rx_eth_src_mac;
    wire [15:0] rx_eth_type;
    wire [7:0]  rx_eth_payload_tdata;
    wire        rx_eth_payload_tvalid, rx_eth_payload_tready;
    wire        rx_eth_payload_tlast, rx_eth_payload_tuser;

    // TX: udp_complete.m_eth_* → eth_axis_tx → MAC
    wire        tx_eth_hdr_valid, tx_eth_hdr_ready;
    wire [47:0] tx_eth_dest_mac, tx_eth_src_mac;
    wire [15:0] tx_eth_type;
    wire [7:0]  tx_eth_payload_tdata;
    wire        tx_eth_payload_tvalid, tx_eth_payload_tready;
    wire        tx_eth_payload_tlast, tx_eth_payload_tuser;

    // -------------------------------------------------------------------------
    // 7) UDP RX (本工程不消费, 但 ARP 等需要)
    // -------------------------------------------------------------------------
    wire        rx_udp_payload_tvalid, rx_udp_payload_tlast, rx_udp_payload_tuser;
    wire [7:0]  rx_udp_payload_tdata;

    // -------------------------------------------------------------------------
    // 8) eth_axis_rx: 把 MAC RX 字节流解析成 eth header + payload
    // -------------------------------------------------------------------------
    eth_axis_rx u_eth_axis_rx (
        .clk(clk125), .rst(rst125),
        .s_axis_tdata (rx_axis_tdata),
        .s_axis_tvalid(rx_axis_tvalid),
        .s_axis_tready(rx_axis_tready),
        .s_axis_tlast (rx_axis_tlast),
        .s_axis_tuser (rx_axis_tuser),
        .m_eth_hdr_valid           (rx_eth_hdr_valid),
        .m_eth_hdr_ready           (rx_eth_hdr_ready),
        .m_eth_dest_mac            (rx_eth_dest_mac),
        .m_eth_src_mac             (rx_eth_src_mac),
        .m_eth_type                (rx_eth_type),
        .m_eth_payload_axis_tdata  (rx_eth_payload_tdata),
        .m_eth_payload_axis_tvalid (rx_eth_payload_tvalid),
        .m_eth_payload_axis_tready (rx_eth_payload_tready),
        .m_eth_payload_axis_tlast  (rx_eth_payload_tlast),
        .m_eth_payload_axis_tuser  (rx_eth_payload_tuser),
        .busy(),
        .error_header_early_termination()
    );

    // -------------------------------------------------------------------------
    // 9) eth_axis_tx: 把 eth header + payload 拼成 MAC TX 字节流
    // -------------------------------------------------------------------------
    eth_axis_tx u_eth_axis_tx (
        .clk(clk125), .rst(rst125),
        .s_eth_hdr_valid           (tx_eth_hdr_valid),
        .s_eth_hdr_ready           (tx_eth_hdr_ready),
        .s_eth_dest_mac            (tx_eth_dest_mac),
        .s_eth_src_mac             (tx_eth_src_mac),
        .s_eth_type                (tx_eth_type),
        .s_eth_payload_axis_tdata  (tx_eth_payload_tdata),
        .s_eth_payload_axis_tvalid (tx_eth_payload_tvalid),
        .s_eth_payload_axis_tready (tx_eth_payload_tready),
        .s_eth_payload_axis_tlast  (tx_eth_payload_tlast),
        .s_eth_payload_axis_tuser  (tx_eth_payload_tuser),
        .m_axis_tdata (tx_axis_tdata),
        .m_axis_tvalid(tx_axis_tvalid),
        .m_axis_tready(tx_axis_tready),
        .m_axis_tlast (tx_axis_tlast),
        .m_axis_tuser (tx_axis_tuser),
        .busy()
    );

    // -------------------------------------------------------------------------
    // 10) UDP/IP/ARP 协议栈
    // -------------------------------------------------------------------------
    udp_complete u_udp (
        .clk(clk125), .rst(rst125),

        // ---- Ethernet frame in (来自 eth_axis_rx) ----
        .s_eth_hdr_valid           (rx_eth_hdr_valid),
        .s_eth_hdr_ready           (rx_eth_hdr_ready),
        .s_eth_dest_mac            (rx_eth_dest_mac),
        .s_eth_src_mac             (rx_eth_src_mac),
        .s_eth_type                (rx_eth_type),
        .s_eth_payload_axis_tdata  (rx_eth_payload_tdata),
        .s_eth_payload_axis_tvalid (rx_eth_payload_tvalid),
        .s_eth_payload_axis_tready (rx_eth_payload_tready),
        .s_eth_payload_axis_tlast  (rx_eth_payload_tlast),
        .s_eth_payload_axis_tuser  (rx_eth_payload_tuser),

        // ---- Ethernet frame out (送 eth_axis_tx) ----
        .m_eth_hdr_valid           (tx_eth_hdr_valid),
        .m_eth_hdr_ready           (tx_eth_hdr_ready),
        .m_eth_dest_mac            (tx_eth_dest_mac),
        .m_eth_src_mac             (tx_eth_src_mac),
        .m_eth_type                (tx_eth_type),
        .m_eth_payload_axis_tdata  (tx_eth_payload_tdata),
        .m_eth_payload_axis_tvalid (tx_eth_payload_tvalid),
        .m_eth_payload_axis_tready (tx_eth_payload_tready),
        .m_eth_payload_axis_tlast  (tx_eth_payload_tlast),
        .m_eth_payload_axis_tuser  (tx_eth_payload_tuser),

        // ---- IP frame in (本工程不发 raw IP, 全部接 0) ----
        .s_ip_hdr_valid(1'b0), .s_ip_hdr_ready(),
        .s_ip_dscp(6'd0), .s_ip_ecn(2'd0), .s_ip_length(16'd0),
        .s_ip_ttl(8'd0), .s_ip_protocol(8'd0),
        .s_ip_source_ip(32'd0), .s_ip_dest_ip(32'd0),
        .s_ip_payload_axis_tdata(8'd0),
        .s_ip_payload_axis_tvalid(1'b0),
        .s_ip_payload_axis_tready(),
        .s_ip_payload_axis_tlast(1'b0),
        .s_ip_payload_axis_tuser(1'b0),

        // ---- IP frame out (本工程不消费 raw IP, 全部丢弃) ----
        .m_ip_hdr_valid(),  .m_ip_hdr_ready(1'b1),
        .m_ip_eth_dest_mac(), .m_ip_eth_src_mac(), .m_ip_eth_type(),
        .m_ip_version(), .m_ip_ihl(), .m_ip_dscp(), .m_ip_ecn(),
        .m_ip_length(), .m_ip_identification(), .m_ip_flags(),
        .m_ip_fragment_offset(), .m_ip_ttl(), .m_ip_protocol(),
        .m_ip_header_checksum(), .m_ip_source_ip(), .m_ip_dest_ip(),
        .m_ip_payload_axis_tdata(),
        .m_ip_payload_axis_tvalid(),
        .m_ip_payload_axis_tready(1'b1),
        .m_ip_payload_axis_tlast(),
        .m_ip_payload_axis_tuser(),

        // ---- UDP frame in (来自 udp_lockin_tx) ----
        .s_udp_hdr_valid           (udp_hdr_valid),
        .s_udp_hdr_ready           (udp_hdr_ready),
        .s_udp_ip_dscp             (udp_ip_dscp),
        .s_udp_ip_ecn              (udp_ip_ecn),
        .s_udp_ip_ttl              (udp_ip_ttl),
        .s_udp_ip_source_ip        (udp_ip_source_ip),
        .s_udp_ip_dest_ip          (udp_ip_dest_ip),
        .s_udp_source_port         (udp_source_port),
        .s_udp_dest_port           (udp_dest_port),
        .s_udp_length              (udp_length),
        .s_udp_checksum            (udp_checksum),
        .s_udp_payload_axis_tdata  (udp_payload_tdata),
        .s_udp_payload_axis_tvalid (udp_payload_tvalid),
        .s_udp_payload_axis_tready (udp_payload_tready),
        .s_udp_payload_axis_tlast  (udp_payload_tlast),
        .s_udp_payload_axis_tuser  (udp_payload_tuser),

        // ---- UDP frame out (本工程不消费, 全部丢弃) ----
        .m_udp_hdr_valid(),  .m_udp_hdr_ready(1'b1),
        .m_udp_eth_dest_mac(), .m_udp_eth_src_mac(), .m_udp_eth_type(),
        .m_udp_ip_version(), .m_udp_ip_ihl(), .m_udp_ip_dscp(), .m_udp_ip_ecn(),
        .m_udp_ip_length(), .m_udp_ip_identification(), .m_udp_ip_flags(),
        .m_udp_ip_fragment_offset(), .m_udp_ip_ttl(), .m_udp_ip_protocol(),
        .m_udp_ip_header_checksum(), .m_udp_ip_source_ip(), .m_udp_ip_dest_ip(),
        .m_udp_source_port(), .m_udp_dest_port(), .m_udp_length(), .m_udp_checksum(),
        .m_udp_payload_axis_tdata (rx_udp_payload_tdata),
        .m_udp_payload_axis_tvalid(rx_udp_payload_tvalid),
        .m_udp_payload_axis_tready(1'b1),
        .m_udp_payload_axis_tlast (rx_udp_payload_tlast),
        .m_udp_payload_axis_tuser (rx_udp_payload_tuser),

        // ---- 状态/错误 ----
        .ip_rx_busy(), .ip_tx_busy(), .udp_rx_busy(), .udp_tx_busy(),
        .ip_rx_error_header_early_termination(),
        .ip_rx_error_payload_early_termination(),
        .ip_rx_error_invalid_header(),
        .ip_rx_error_invalid_checksum(),
        .ip_tx_error_payload_early_termination(),
        .ip_tx_error_arp_failed(),
        .udp_rx_error_header_early_termination(),
        .udp_rx_error_payload_early_termination(),
        .udp_tx_error_payload_early_termination(),

        // ---- 配置 ----
        .local_mac      (LOCAL_MAC),
        .local_ip       (LOCAL_IP),
        .gateway_ip     (GATEWAY_IP),
        .subnet_mask    (SUBNET_MASK),
        .clear_arp_cache(1'b0)
    );

    // -------------------------------------------------------------------------
    // 11) 千兆 MAC + RGMII PHY 接口
    // -------------------------------------------------------------------------
    eth_mac_1g_rgmii_fifo #(
        .TARGET             ("XILINX"),
        .IODDR_STYLE        ("IODDR"),
        .CLOCK_INPUT_STYLE  ("BUFR"),
        .USE_CLK90          ("TRUE"),
        .AXIS_DATA_WIDTH    (8),
        .ENABLE_PADDING     (1),
        .MIN_FRAME_LENGTH   (64),
        .TX_FIFO_DEPTH      (4096),
        .RX_FIFO_DEPTH      (4096)
    ) u_eth_mac (
        .gtx_clk             (clk125),
        .gtx_clk90           (clk125_90),
        .gtx_rst             (rst125),
        .logic_clk           (clk125),
        .logic_rst           (rst125),

        .tx_axis_tdata       (tx_axis_tdata),
        .tx_axis_tkeep       (1'b1),                // 8-bit AXIS, KEEP_WIDTH=1
        .tx_axis_tvalid      (tx_axis_tvalid),
        .tx_axis_tready      (tx_axis_tready),
        .tx_axis_tlast       (tx_axis_tlast),
        .tx_axis_tuser       (tx_axis_tuser),

        .rx_axis_tdata       (rx_axis_tdata),
        .rx_axis_tkeep       (),                    // 不用 (单字节)
        .rx_axis_tvalid      (rx_axis_tvalid),
        .rx_axis_tready      (rx_axis_tready),
        .rx_axis_tlast       (rx_axis_tlast),
        .rx_axis_tuser       (rx_axis_tuser),

        .rgmii_rx_clk        (eth_rxc),
        .rgmii_rxd           (eth_rxd),
        .rgmii_rx_ctl        (eth_rxctl),
        .rgmii_tx_clk        (eth_txc),
        .rgmii_txd           (eth_txd),
        .rgmii_tx_ctl        (eth_txctl),

        .tx_fifo_overflow    (),
        .tx_fifo_bad_frame   (),
        .tx_fifo_good_frame  (),
        .rx_error_bad_frame  (),
        .rx_error_bad_fcs    (),
        .rx_fifo_overflow    (),
        .rx_fifo_bad_frame   (),
        .rx_fifo_good_frame  (),
        .speed               (link_speed),

        // 配置端口 (新版 MAC 改名: ifg_delay → cfg_ifg)
        .cfg_ifg             (8'd12),
        .cfg_tx_enable       (1'b1),
        .cfg_rx_enable       (1'b1)
    );

    assign link_up = phy_ready & (link_speed == 2'b10);

endmodule
