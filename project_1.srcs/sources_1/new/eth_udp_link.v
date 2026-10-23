`timescale 1ns / 1ps
// =============================================================================
//  eth_udp_link.v
//
//  以太网 UDP 双向链路 (替代 FT245BL): 上位机命令下行 + 字节流上行
//
//  对 usb_commend 呈现与 ft245_rx / ft245_tx 相同的字节接口 (lockin_clk 域):
//    下行: PC → UDP 目的端口 LOCAL_PORT → 载荷字节 → rec_data / rec_done
//    上行: send_en / send_data → 异步 FIFO → udp_stream_tx 打包 → PC
//  上行目的地址 = 最近一次发来命令的 PC 源 IP / 源端口 (上电默认 DEST_IP:DEST_PORT).
//  命令包可发往本机 IP 或子网广播地址 (上位机探测 FPGA 用广播).
//
//      [65 MHz 域]                 [125 MHz 域]
//   send_en/send_data ─► FIFO ─► udp_stream_tx ─┐
//                                                ├─ udp_complete ─ eth_axis_rx/tx ─ MAC ─ RGMII
//   rec_data/rec_done ◄─ FIFO ◄─ 端口过滤 ◄──────┘
//
//  RGMII RX IDELAY 自动扫描: 每个 tap 停留 0.5 s, 收到 ≥3 个好帧且无 CRC 错帧即判"可用";
//  扫完 32 档后锁定最长连续可用区间的中点. 一档都不可用则从头再扫 (需要 PC 有流量,
//  上位机连接时会持续广播探测包). 锁定后若持续只收到坏帧则重新扫描.
// =============================================================================
module eth_udp_link #(
    parameter [47:0] LOCAL_MAC   = 48'h02_00_00_00_00_01,
    parameter [31:0] LOCAL_IP    = {8'd192, 8'd168, 8'd99, 8'd10},
    parameter [31:0] GATEWAY_IP  = {8'd192, 8'd168, 8'd99, 8'd1},
    parameter [31:0] SUBNET_MASK = {8'd255, 8'd255, 8'd255, 8'd0},
    parameter [15:0] LOCAL_PORT  = 16'd1234,
    parameter [31:0] DEST_IP     = {8'd192, 8'd168, 8'd99, 8'd100},
    parameter [15:0] DEST_PORT   = 16'd7777,
    parameter        TX_FIFO_DEPTH = 8192,
    parameter        SIM_FAST_SCAN = 0          // 仿真用: 缩短扫描/延时
)(
    input  wire        pl_clk_50m,
    input  wire        sys_rst,                // 高有效

    // usb_commend 字节接口 (lockin_clk 域)
    input  wire        lockin_clk,
    input  wire        lockin_rst,             // 高有效
    output reg  [7:0]  rec_data,
    output reg         rec_done,
    input  wire        rx_ready,
    output wire        rx_pending,
    input  wire        send_en,
    input  wire [7:0]  send_data,
    output reg         tx_done,
    output wire        tx_busy,

    // RGMII PHY (RTL8211E)
    input  wire        eth_rxc,
    input  wire        eth_rxctl,
    input  wire [3:0]  eth_rxd,
    output wire        eth_txc,
    output wire        eth_txctl,
    output wire [3:0]  eth_txd,
    output wire        eth_nrst,
    output wire        eth_mdc,
    inout  wire        eth_mdio,

    // LED: led1 慢闪 = IDELAY 扫描中, 常亮 = 已锁定; led2 闪 = 收到命令 / 发出 UDP 包
    output wire        pl_led1,
    output wire        pl_led2
);

    // -------------------------------------------------------------------------
    // 时钟 / 复位
    // -------------------------------------------------------------------------
    wire clk125, clk125_90, clk200, mmcm_locked;

    clk_wiz_eth u_clk_wiz_eth (
        .clk_in1  (pl_clk_50m),
        .clk_out1 (clk125),
        .clk_out2 (clk125_90),
        .clk_out3 (clk200),
        .locked   (mmcm_locked),
        .reset    (sys_rst)
    );

    reg [3:0] rst125_pipe = 4'b1111;
    wire rst125 = rst125_pipe[3];
    always @(posedge clk125) begin
        if (sys_rst | ~mmcm_locked)
            rst125_pipe <= 4'b1111;
        else
            rst125_pipe <= {rst125_pipe[2:0], 1'b0};
    end

    reg [3:0] rst200_pipe = 4'b1111;
    wire rst200 = rst200_pipe[3];
    always @(posedge clk200) begin
        if (sys_rst | ~mmcm_locked)
            rst200_pipe <= 4'b1111;
        else
            rst200_pipe <= {rst200_pipe[2:0], 1'b0};
    end

    reg [3:0] rst65_pipe = 4'b1111;
    wire rst65 = rst65_pipe[3];
    always @(posedge lockin_clk) begin
        if (lockin_rst)
            rst65_pipe <= 4'b1111;
        else
            rst65_pipe <= {rst65_pipe[2:0], 1'b0};
    end

    // 两侧都出复位后才放开 FIFO 复位 (XPM 异步 FIFO 复位期间两侧时钟须已稳定)
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst125_in65 = 3'b111;
    (* ASYNC_REG = "TRUE" *) reg [2:0] rst65_in125 = 3'b111;
    always @(posedge lockin_clk) rst125_in65 <= {rst125_in65[1:0], rst125};
    always @(posedge clk125)     rst65_in125 <= {rst65_in125[1:0], rst65};
    wire txf_rst = rst65  | rst125_in65[2];     // TX FIFO 写侧 = lockin_clk
    wire rxf_rst = rst125 | rst65_in125[2];     // RX FIFO 写侧 = clk125

    // -------------------------------------------------------------------------
    // RGMII RX IDELAY
    // -------------------------------------------------------------------------
    wire [4:0] rx_pin = {eth_rxctl, eth_rxd};
    wire [4:0] rx_dly;
    wire [3:0] eth_rxd_dly   = rx_dly[3:0];
    wire       eth_rxctl_dly = rx_dly[4];
    reg  [4:0] idelay_tap;
    reg        idelay_load;

    (* IODELAY_GROUP = "rgmii_idelay_group" *)
    IDELAYCTRL u_idelayctrl (
        .RDY    (),
        .REFCLK (clk200),
        .RST    (rst200)
    );

    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : g_rx_dly
            (* IODELAY_GROUP = "rgmii_idelay_group" *)
            IDELAYE2 #(
                .CINVCTRL_SEL          ("FALSE"),
                .DELAY_SRC             ("IDATAIN"),
                .HIGH_PERFORMANCE_MODE ("TRUE"),
                .IDELAY_TYPE           ("VAR_LOAD"),
                .IDELAY_VALUE          (0),
                .PIPE_SEL              ("FALSE"),
                .REFCLK_FREQUENCY      (200.0),
                .SIGNAL_PATTERN        ("DATA")
            ) u_idelay (
                .CNTVALUEOUT(),
                .DATAOUT    (rx_dly[gi]),
                .C          (clk125),
                .CE         (1'b0),
                .CINVCTRL   (1'b0),
                .CNTVALUEIN (idelay_tap),
                .DATAIN     (1'b0),
                .IDATAIN    (rx_pin[gi]),
                .INC        (1'b0),
                .LD         (idelay_load),
                .LDPIPEEN   (1'b0),
                .REGRST     (1'b0)
            );
        end
    endgenerate

    // -------------------------------------------------------------------------
    // PHY 硬复位
    // -------------------------------------------------------------------------
    wire phy_ready;
    eth_phy_init #(
        .CLK_FREQ_HZ      (125_000_000),
        .PHY_RST_LOW_MS   (SIM_FAST_SCAN ? 1 : 20),
        .PHY_INIT_WAIT_MS (SIM_FAST_SCAN ? 1 : 200)
    ) u_phy_init (
        .clk       (clk125),
        .rst       (rst125),
        .phy_rst_n (eth_nrst),
        .phy_ready (phy_ready)
    );

    assign eth_mdc  = 1'b0;
    assign eth_mdio = 1'bz;

    // -------------------------------------------------------------------------
    // MAC ↔ eth_axis_rx/tx ↔ udp_complete
    // -------------------------------------------------------------------------
    wire [7:0]  rx_axis_tdata,  tx_axis_tdata;
    wire        rx_axis_tvalid, tx_axis_tvalid;
    wire        rx_axis_tready, tx_axis_tready;
    wire        rx_axis_tlast,  tx_axis_tlast;
    wire        rx_axis_tuser,  tx_axis_tuser;

    wire        rx_good_frame, rx_bad_fcs;

    eth_mac_1g_rgmii_fifo #(
        .TARGET             ("XILINX"),
        .IODDR_STYLE        ("IODDR"),
        .CLOCK_INPUT_STYLE  ("BUFR"),
        .USE_CLK90          ("FALSE"),    // RTL8211E 内部 TXDLY 已开, FPGA 送边沿对齐
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
        .tx_axis_tkeep       (1'b1),
        .tx_axis_tvalid      (tx_axis_tvalid),
        .tx_axis_tready      (tx_axis_tready),
        .tx_axis_tlast       (tx_axis_tlast),
        .tx_axis_tuser       (tx_axis_tuser),
        .rx_axis_tdata       (rx_axis_tdata),
        .rx_axis_tkeep       (),
        .rx_axis_tvalid      (rx_axis_tvalid),
        .rx_axis_tready      (rx_axis_tready),
        .rx_axis_tlast       (rx_axis_tlast),
        .rx_axis_tuser       (rx_axis_tuser),
        .rgmii_rx_clk        (eth_rxc),
        .rgmii_rxd           (eth_rxd_dly),
        .rgmii_rx_ctl        (eth_rxctl_dly),
        .rgmii_tx_clk        (eth_txc),
        .rgmii_txd           (eth_txd),
        .rgmii_tx_ctl        (eth_txctl),
        .tx_fifo_overflow    (),
        .tx_fifo_bad_frame   (),
        .tx_fifo_good_frame  (),
        .rx_error_bad_frame  (),
        .rx_error_bad_fcs    (rx_bad_fcs),
        .rx_fifo_overflow    (),
        .rx_fifo_bad_frame   (),
        .rx_fifo_good_frame  (rx_good_frame),
        .speed               (),
        .cfg_ifg             (8'd12),
        .cfg_tx_enable       (1'b1),
        .cfg_rx_enable       (1'b1)
    );

    wire        rx_eth_hdr_valid, rx_eth_hdr_ready;
    wire [47:0] rx_eth_dest_mac, rx_eth_src_mac;
    wire [15:0] rx_eth_type;
    wire [7:0]  rx_eth_payload_tdata;
    wire        rx_eth_payload_tvalid, rx_eth_payload_tready;
    wire        rx_eth_payload_tlast, rx_eth_payload_tuser;

    wire        tx_eth_hdr_valid, tx_eth_hdr_ready;
    wire [47:0] tx_eth_dest_mac, tx_eth_src_mac;
    wire [15:0] tx_eth_type;
    wire [7:0]  tx_eth_payload_tdata;
    wire        tx_eth_payload_tvalid, tx_eth_payload_tready;
    wire        tx_eth_payload_tlast, tx_eth_payload_tuser;

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

    // UDP 上行 (udp_stream_tx → udp_complete)
    wire        utx_hdr_valid, utx_hdr_ready;
    wire [5:0]  utx_ip_dscp;
    wire [1:0]  utx_ip_ecn;
    wire [7:0]  utx_ip_ttl;
    wire [31:0] utx_ip_source_ip, utx_ip_dest_ip;
    wire [15:0] utx_source_port, utx_dest_port, utx_length, utx_checksum;
    wire [7:0]  utx_tdata;
    wire        utx_tvalid, utx_tready, utx_tlast, utx_tuser;

    // UDP 下行 (udp_complete → 命令过滤)
    wire        urx_hdr_valid;
    wire [31:0] urx_ip_source_ip, urx_ip_dest_ip;
    wire [15:0] urx_source_port, urx_dest_port;
    wire [7:0]  urx_tdata;
    wire        urx_tvalid;

    udp_complete u_udp (
        .clk(clk125), .rst(rst125),

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

        .s_ip_hdr_valid(1'b0), .s_ip_hdr_ready(),
        .s_ip_dscp(6'd0), .s_ip_ecn(2'd0), .s_ip_length(16'd0),
        .s_ip_ttl(8'd0), .s_ip_protocol(8'd0),
        .s_ip_source_ip(32'd0), .s_ip_dest_ip(32'd0),
        .s_ip_payload_axis_tdata(8'd0),
        .s_ip_payload_axis_tvalid(1'b0),
        .s_ip_payload_axis_tready(),
        .s_ip_payload_axis_tlast(1'b0),
        .s_ip_payload_axis_tuser(1'b0),

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

        .s_udp_hdr_valid           (utx_hdr_valid),
        .s_udp_hdr_ready           (utx_hdr_ready),
        .s_udp_ip_dscp             (utx_ip_dscp),
        .s_udp_ip_ecn              (utx_ip_ecn),
        .s_udp_ip_ttl              (utx_ip_ttl),
        .s_udp_ip_source_ip        (utx_ip_source_ip),
        .s_udp_ip_dest_ip          (utx_ip_dest_ip),
        .s_udp_source_port         (utx_source_port),
        .s_udp_dest_port           (utx_dest_port),
        .s_udp_length              (utx_length),
        .s_udp_checksum            (utx_checksum),
        .s_udp_payload_axis_tdata  (utx_tdata),
        .s_udp_payload_axis_tvalid (utx_tvalid),
        .s_udp_payload_axis_tready (utx_tready),
        .s_udp_payload_axis_tlast  (utx_tlast),
        .s_udp_payload_axis_tuser  (utx_tuser),

        .m_udp_hdr_valid(urx_hdr_valid),  .m_udp_hdr_ready(1'b1),
        .m_udp_eth_dest_mac(), .m_udp_eth_src_mac(), .m_udp_eth_type(),
        .m_udp_ip_version(), .m_udp_ip_ihl(), .m_udp_ip_dscp(), .m_udp_ip_ecn(),
        .m_udp_ip_length(), .m_udp_ip_identification(), .m_udp_ip_flags(),
        .m_udp_ip_fragment_offset(), .m_udp_ip_ttl(), .m_udp_ip_protocol(),
        .m_udp_ip_header_checksum(),
        .m_udp_ip_source_ip(urx_ip_source_ip), .m_udp_ip_dest_ip(urx_ip_dest_ip),
        .m_udp_source_port(urx_source_port), .m_udp_dest_port(urx_dest_port),
        .m_udp_length(), .m_udp_checksum(),
        .m_udp_payload_axis_tdata (urx_tdata),
        .m_udp_payload_axis_tvalid(urx_tvalid),
        .m_udp_payload_axis_tready(1'b1),
        .m_udp_payload_axis_tlast (),
        .m_udp_payload_axis_tuser (),

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

        .local_mac      (LOCAL_MAC),
        .local_ip       (LOCAL_IP),
        .gateway_ip     (GATEWAY_IP),
        .subnet_mask    (SUBNET_MASK),
        .clear_arp_cache(1'b0)
    );

    // -------------------------------------------------------------------------
    // 下行: 命令包过滤 + 记录 PC 地址 + 载荷字节进 RX FIFO (125 → 65 MHz)
    // -------------------------------------------------------------------------
    localparam [31:0] SUBNET_BCAST = LOCAL_IP | ~SUBNET_MASK;

    wire cmd_hdr = (urx_dest_port == LOCAL_PORT)
                && ((urx_ip_dest_ip == LOCAL_IP) || (urx_ip_dest_ip == SUBNET_BCAST)
                    || (urx_ip_dest_ip == 32'hFFFF_FFFF));

    reg        rx_accept;
    reg [31:0] peer_ip;
    reg [15:0] peer_port;

    always @(posedge clk125) begin
        if (rst125) begin
            rx_accept <= 1'b0;
            peer_ip   <= DEST_IP;
            peer_port <= DEST_PORT;
        end else if (urx_hdr_valid) begin
            rx_accept <= cmd_hdr;
            if (cmd_hdr) begin
                peer_ip   <= urx_ip_source_ip;
                peer_port <= urx_source_port;
            end
        end
    end

    // 载荷首字节可能与包头同拍到达
    wire rx_accept_now = urx_hdr_valid ? cmd_hdr : rx_accept;

    wire       rxf_full, rxf_empty, rxf_wr_busy, rxf_rd_busy;
    wire [7:0] rxf_dout;
    wire       rxf_wr_en = urx_tvalid && rx_accept_now && !rxf_full && !rxf_wr_busy;
    wire       rxf_rd_en;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE ("distributed"),
        .FIFO_WRITE_DEPTH (512),
        .WRITE_DATA_WIDTH (8),
        .READ_DATA_WIDTH  (8),
        .READ_MODE        ("fwft"),
        .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES ("0000"),
        .CDC_SYNC_STAGES  (2)
    ) u_rx_fifo (
        .rst          (rxf_rst),
        .wr_clk       (clk125),
        .wr_en        (rxf_wr_en),
        .din          (urx_tdata),
        .full         (rxf_full),
        .wr_rst_busy  (rxf_wr_busy),
        .rd_clk       (lockin_clk),
        .rd_en        (rxf_rd_en),
        .dout         (rxf_dout),
        .empty        (rxf_empty),
        .rd_rst_busy  (rxf_rd_busy),
        .wr_data_count(), .rd_data_count(),
        .almost_empty(), .almost_full(), .data_valid(),
        .dbiterr(), .overflow(), .prog_empty(), .prog_full(),
        .sbiterr(), .underflow(), .wr_ack(),
        .injectdbiterr(1'b0), .injectsbiterr(1'b0),
        .sleep        (1'b0)
    );

    // 每 2 拍最多交付 1 字节: rx_ready 在交付的下一拍才反映 usb_commend 的新状态
    assign rxf_rd_en = !rxf_empty && !rxf_rd_busy && rx_ready && !rec_done;
    assign rx_pending = (!rxf_empty && !rxf_rd_busy) || rec_done;

    always @(posedge lockin_clk) begin
        if (rst65) begin
            rec_done <= 1'b0;
            rec_data <= 8'd0;
        end else begin
            rec_done <= rxf_rd_en;
            if (rxf_rd_en)
                rec_data <= rxf_dout;
        end
    end

    // -------------------------------------------------------------------------
    // 上行: send_en 上升沿写一字节进 TX FIFO (65 → 125 MHz), 下一拍回 tx_done.
    //       FIFO 满则丢字节 (上位机靠同步头 + CRC 重新对齐), 不阻塞 usb_commend.
    // -------------------------------------------------------------------------
    reg  send_en_d;
    wire tx_push = send_en && !send_en_d;

    wire       txf_full, txf_empty, txf_wr_busy, txf_rd_busy;
    wire [7:0] txf_dout;
    wire       txf_rd_en;

    always @(posedge lockin_clk) begin
        if (rst65) begin
            send_en_d <= 1'b0;
            tx_done   <= 1'b0;
        end else begin
            send_en_d <= send_en;
            tx_done   <= tx_push;
        end
    end

    assign tx_busy = 1'b0;

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE ("block"),
        .FIFO_WRITE_DEPTH (TX_FIFO_DEPTH),
        .WRITE_DATA_WIDTH (8),
        .READ_DATA_WIDTH  (8),
        .READ_MODE        ("fwft"),
        .FIFO_READ_LATENCY(0),
        .USE_ADV_FEATURES ("0000"),
        .CDC_SYNC_STAGES  (2)
    ) u_tx_fifo (
        .rst          (txf_rst),
        .wr_clk       (lockin_clk),
        .wr_en        (tx_push && !txf_full && !txf_wr_busy),
        .din          (send_data),
        .full         (txf_full),
        .wr_rst_busy  (txf_wr_busy),
        .rd_clk       (clk125),
        .rd_en        (txf_rd_en),
        .dout         (txf_dout),
        .empty        (txf_empty),
        .rd_rst_busy  (txf_rd_busy),
        .wr_data_count(), .rd_data_count(),
        .almost_empty(), .almost_full(), .data_valid(),
        .dbiterr(), .overflow(), .prog_empty(), .prog_full(),
        .sbiterr(), .underflow(), .wr_ack(),
        .injectdbiterr(1'b0), .injectsbiterr(1'b0),
        .sleep        (1'b0)
    );

    wire pkt_sent;

    udp_stream_tx #(
        .LOCAL_IP    (LOCAL_IP),
        .SRC_PORT    (LOCAL_PORT),
        .MAX_PAYLOAD (1024),
        .IDLE_CYC    (256)
    ) u_stream_tx (
        .clk        (clk125),
        .rst        (rst125),
        .enable     (phy_ready),
        .fifo_dout  (txf_dout),
        .fifo_empty (txf_empty | txf_rd_busy),
        .fifo_rd_en (txf_rd_en),
        .dest_ip    (peer_ip),
        .dest_port  (peer_port),
        .m_udp_hdr_valid           (utx_hdr_valid),
        .m_udp_hdr_ready           (utx_hdr_ready),
        .m_udp_ip_dscp             (utx_ip_dscp),
        .m_udp_ip_ecn              (utx_ip_ecn),
        .m_udp_ip_ttl              (utx_ip_ttl),
        .m_udp_ip_source_ip        (utx_ip_source_ip),
        .m_udp_ip_dest_ip          (utx_ip_dest_ip),
        .m_udp_source_port         (utx_source_port),
        .m_udp_dest_port           (utx_dest_port),
        .m_udp_length              (utx_length),
        .m_udp_checksum            (utx_checksum),
        .m_udp_payload_axis_tdata  (utx_tdata),
        .m_udp_payload_axis_tvalid (utx_tvalid),
        .m_udp_payload_axis_tready (utx_tready),
        .m_udp_payload_axis_tlast  (utx_tlast),
        .m_udp_payload_axis_tuser  (utx_tuser),
        .pkt_sent   (pkt_sent)
    );

    // -------------------------------------------------------------------------
    // IDELAY 扫描
    // -------------------------------------------------------------------------
    localparam [31:0] DWELL_CYC  = SIM_FAST_SCAN ? 32'd2_000 : 32'd62_500_000;   // 0.5 s
    localparam [31:0] SETTLE_CYC = SIM_FAST_SCAN ? 32'd100   : 32'd1_250_000;    // 10 ms
    localparam [31:0] WATCH_CYC  = SIM_FAST_SCAN ? 32'd4_000 : 32'd125_000_000;  // 1 s
    localparam        MIN_GOOD   = 3;

    localparam SC_SETTLE = 3'd0,
               SC_DWELL  = 3'd1,
               SC_PICK   = 3'd2,
               SC_LOCKED = 3'd3;

    reg [2:0]  sc_state;
    reg [31:0] sc_timer;
    reg [3:0]  sc_good;
    reg [3:0]  sc_bad;
    reg [31:0] sc_pass;          // 每个 tap 是否可用
    reg [5:0]  pk_i;
    reg [4:0]  pk_cur_start, pk_best_start;
    reg [5:0]  pk_cur_len,   pk_best_len;
    reg        scan_locked;

    always @(posedge clk125) begin
        idelay_load <= 1'b0;
        if (rst125 || !phy_ready) begin
            sc_state    <= SC_SETTLE;
            sc_timer    <= SETTLE_CYC;
            sc_good     <= 4'd0;
            sc_bad      <= 4'd0;
            sc_pass     <= 32'd0;
            idelay_tap  <= 5'd0;
            idelay_load <= 1'b1;
            scan_locked <= 1'b0;
        end else begin
            case (sc_state)
                SC_SETTLE: begin
                    sc_good <= 4'd0;
                    sc_bad  <= 4'd0;
                    if (sc_timer != 0)
                        sc_timer <= sc_timer - 1'b1;
                    else begin
                        sc_timer <= DWELL_CYC;
                        sc_state <= SC_DWELL;
                    end
                end

                SC_DWELL: begin
                    if (rx_good_frame && sc_good != 4'hF) sc_good <= sc_good + 1'b1;
                    if (rx_bad_fcs    && sc_bad  != 4'hF) sc_bad  <= sc_bad  + 1'b1;
                    if (sc_timer != 0)
                        sc_timer <= sc_timer - 1'b1;
                    else begin
                        sc_pass[idelay_tap] <= (sc_good >= MIN_GOOD) && (sc_bad == 0);
                        if (idelay_tap == 5'd31) begin
                            pk_i          <= 6'd0;
                            pk_cur_len    <= 6'd0;
                            pk_best_len   <= 6'd0;
                            pk_best_start <= 5'd0;
                            sc_state      <= SC_PICK;
                        end else begin
                            idelay_tap  <= idelay_tap + 1'b1;
                            idelay_load <= 1'b1;
                            sc_timer    <= SETTLE_CYC;
                            sc_state    <= SC_SETTLE;
                        end
                    end
                end

                // 找最长连续可用区间, 取中点
                SC_PICK: begin
                    if (pk_i < 6'd32) begin
                        if (sc_pass[pk_i[4:0]]) begin
                            if (pk_cur_len == 0) pk_cur_start <= pk_i[4:0];
                            pk_cur_len <= pk_cur_len + 1'b1;
                            if (pk_cur_len + 1'b1 > pk_best_len) begin
                                pk_best_len   <= pk_cur_len + 1'b1;
                                pk_best_start <= (pk_cur_len == 0) ? pk_i[4:0] : pk_cur_start;
                            end
                        end else begin
                            pk_cur_len <= 6'd0;
                        end
                        pk_i <= pk_i + 1'b1;
                    end else begin
                        idelay_load <= 1'b1;
                        sc_timer    <= SETTLE_CYC;
                        sc_pass     <= 32'd0;
                        if (pk_best_len != 0) begin
                            idelay_tap  <= pk_best_start + pk_best_len[5:1];
                            sc_timer    <= WATCH_CYC;
                            scan_locked <= 1'b1;
                            sc_state    <= SC_LOCKED;
                        end else begin
                            idelay_tap  <= 5'd0;
                            sc_state    <= SC_SETTLE;
                        end
                    end
                end

                // 锁定后监视: 1 s 内只见坏帧 (≥8) 不见好帧则重扫
                SC_LOCKED: begin
                    if (rx_good_frame && sc_good != 4'hF) sc_good <= sc_good + 1'b1;
                    if (rx_bad_fcs    && sc_bad  != 4'hF) sc_bad  <= sc_bad  + 1'b1;
                    if (sc_timer != 0)
                        sc_timer <= sc_timer - 1'b1;
                    else begin
                        sc_timer <= WATCH_CYC;
                        sc_good  <= 4'd0;
                        sc_bad   <= 4'd0;
                        if (sc_good == 0 && sc_bad >= 4'd8) begin
                            scan_locked <= 1'b0;
                            idelay_tap  <= 5'd0;
                            idelay_load <= 1'b1;
                            sc_timer    <= SETTLE_CYC;
                            sc_state    <= SC_SETTLE;
                        end
                    end
                end

                default: sc_state <= SC_SETTLE;
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // LED
    // -------------------------------------------------------------------------
    reg [24:0] blink_cnt;
    reg [22:0] act_cnt;
    always @(posedge clk125) begin
        if (rst125) begin
            blink_cnt <= 25'd0;
            act_cnt   <= 23'd0;
        end else begin
            blink_cnt <= blink_cnt + 1'b1;
            if ((urx_hdr_valid && cmd_hdr) || pkt_sent)
                act_cnt <= 23'd6_250_000;               // 50 ms
            else if (act_cnt != 0)
                act_cnt <= act_cnt - 1'b1;
        end
    end

    assign pl_led1 = phy_ready & (scan_locked | blink_cnt[24]);
    assign pl_led2 = (act_cnt != 0);

endmodule
