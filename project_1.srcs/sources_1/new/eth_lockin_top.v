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
    parameter        FRAME_BYTES = 80,
    // RGMII RX IDELAY auto-scan:
    //   1 = 自动扫描 0..31, 找到第一个能收到 RX 帧的 tap 就锁定
    //   0 = 用 RX_IDELAY_TAP 固定值 (调通后改回 0 用)
    parameter        RX_IDELAY_AUTO = 1,
    parameter        RX_IDELAY_TAP  = 24
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
    output wire         frame_dropped,
    output wire         rx_error_bad_fcs,    // RX CRC 错误脉冲 (诊断, 已拉宽)
    output wire         rx_error_bad_frame,  // RX 帧错误脉冲 (诊断, 已拉宽)
    output wire         rx_frame_activity,   // RX 任意帧活动 (诊断, 已拉宽)
    output wire         rxctl_pin_activity,  // eth_rxctl 引脚级跳变 (诊断, 已拉宽)
    output wire         rxd_all_active,      // 4 位 eth_rxd 全都有跳变 (诊断, 已拉宽)
    output wire [3:0]   rxd_per_bit_active,  // 每位 eth_rxd 单独跳变指示 (调试用)

    // IDELAY 自动扫描状态 (诊断)
    output wire         idelay_scan_locked,  // 1 = 找到能收帧的 tap, 已锁定
    output wire         idelay_scan_failed,  // 1 = 扫完 32 个 tap 都没收到帧
    output wire [4:0]   idelay_scan_tap_now, // 当前正在测试 / 已锁定的 tap 值

    // 协议层活动指示 (用于诊断 RX 解析/TX 发包是否在动)
    output wire         rx_eth_hdr_activity, // eth_axis_rx 每解析出一个 eth header 脉冲 (拉宽)
    output wire         tx_axis_activity     // 任意 TX byte 流出 MAC (拉宽), 包括 ARP 响应
);

    // -------------------------------------------------------------------------
    // 1) 50 MHz → 125 MHz (0°) + 125 MHz (90°) + 200 MHz (IDELAYCTRL refclk)
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

    // 125 MHz 同步复位
    reg [3:0] rst125_pipe = 4'b1111;
    wire rst125 = rst125_pipe[3];
    always @(posedge clk125) begin
        if (sys_rst | ~mmcm_locked)
            rst125_pipe <= 4'b1111;
        else
            rst125_pipe <= {rst125_pipe[2:0], 1'b0};
    end

    // 200 MHz 同步复位 (给 IDELAYCTRL)
    reg [3:0] rst200_pipe = 4'b1111;
    wire rst200 = rst200_pipe[3];
    always @(posedge clk200) begin
        if (sys_rst | ~mmcm_locked)
            rst200_pipe <= 4'b1111;
        else
            rst200_pipe <= {rst200_pipe[2:0], 1'b0};
    end

    // -------------------------------------------------------------------------
    // 1.5) IDELAYCTRL + IDELAYE2 给 RGMII RX 数据加可调延迟 (支持自动扫描)
    //
    //  目的: RTL8211E 在某些 boot-strap 下 RX 数据是边沿对齐 RXC, 此时 IDDR
    //  会在数据跳变沿采样, 导致全部帧 CRC 错误. 这里给 RXD/RXCTL 加可调延迟,
    //  支持上电后自动扫描 0..31, 找到能成功解帧的 tap 后锁定.
    // -------------------------------------------------------------------------
    wire [3:0] eth_rxd_dly;
    wire       eth_rxctl_dly;

    // 当前 tap 值 + 加载脉冲 (由扫描状态机驱动, 见 §1.6)
    wire [4:0] idelay_tap_cur;
    wire       idelay_load;

    (* IODELAY_GROUP = "rgmii_idelay_group" *)
    IDELAYCTRL u_idelayctrl (
        .RDY    (),
        .REFCLK (clk200),
        .RST    (rst200)
    );

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_rxd_dly
            (* IODELAY_GROUP = "rgmii_idelay_group" *)
            IDELAYE2 #(
                .CINVCTRL_SEL          ("FALSE"),
                .DELAY_SRC             ("IDATAIN"),
                .HIGH_PERFORMANCE_MODE ("TRUE"),
                .IDELAY_TYPE           ("VAR_LOAD"),
                .IDELAY_VALUE          (RX_IDELAY_TAP),
                .PIPE_SEL              ("FALSE"),
                .REFCLK_FREQUENCY      (200.0),
                .SIGNAL_PATTERN        ("DATA")
            ) u_idelay_rxd (
                .CNTVALUEOUT(),
                .DATAOUT    (eth_rxd_dly[gi]),
                .C          (clk125),
                .CE         (1'b0),
                .CINVCTRL   (1'b0),
                .CNTVALUEIN (idelay_tap_cur),
                .DATAIN     (1'b0),
                .IDATAIN    (eth_rxd[gi]),
                .INC        (1'b0),
                .LD         (idelay_load),
                .LDPIPEEN   (1'b0),
                .REGRST     (1'b0)
            );
        end
    endgenerate

    (* IODELAY_GROUP = "rgmii_idelay_group" *)
    IDELAYE2 #(
        .CINVCTRL_SEL          ("FALSE"),
        .DELAY_SRC             ("IDATAIN"),
        .HIGH_PERFORMANCE_MODE ("TRUE"),
        .IDELAY_TYPE           ("VAR_LOAD"),
        .IDELAY_VALUE          (RX_IDELAY_TAP),
        .PIPE_SEL              ("FALSE"),
        .REFCLK_FREQUENCY      (200.0),
        .SIGNAL_PATTERN        ("DATA")
    ) u_idelay_rxctl (
        .CNTVALUEOUT(),
        .DATAOUT    (eth_rxctl_dly),
        .C          (clk125),
        .CE         (1'b0),
        .CINVCTRL   (1'b0),
        .CNTVALUEIN (idelay_tap_cur),
        .DATAIN     (1'b0),
        .IDATAIN    (eth_rxctl),
        .INC        (1'b0),
        .LD         (idelay_load),
        .LDPIPEEN   (1'b0),
        .REGRST     (1'b0)
    );

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
    // 这两个 RX 错误指示信号是 MAC 输出, 后面 §12 还要用, 提前声明避免隐式 wire
    wire rx_err_bad_fcs_pulse;
    wire rx_err_bad_frame_pulse;
    wire rx_good_frame_pulse;     // MAC 输出: 收到完整无错的帧 (1 拍脉冲)

    // ★ USE_CLK90 翻面: 之前 TRUE (TXC 滞后 TXD 2ns, 数据中心对齐 TXC),
    //   现在 FALSE (TXC 和 TXD 边沿对齐). RTL8211E 在 LXB-ZYNQ 上的
    //   boot-strap 默认 TXDLY=ON, PHY 内部把 RXC (PHY 视角) 加 2ns 后
    //   再采样 RXD, 所以 FPGA 端送边沿对齐刚刚好.
    eth_mac_1g_rgmii_fifo #(
        .TARGET             ("XILINX"),
        .IODDR_STYLE        ("IODDR"),
        .CLOCK_INPUT_STYLE  ("BUFR"),
        .USE_CLK90          ("FALSE"),     // ★ 之前是 "TRUE", 现在翻成 "FALSE"
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
        .rgmii_rxd           (eth_rxd_dly),     // 经过 IDELAY 移到中心采样
        .rgmii_rx_ctl        (eth_rxctl_dly),   // 同上
        .rgmii_tx_clk        (eth_txc),
        .rgmii_txd           (eth_txd),
        .rgmii_tx_ctl        (eth_txctl),

        .tx_fifo_overflow    (),
        .tx_fifo_bad_frame   (),
        .tx_fifo_good_frame  (),
        .rx_error_bad_frame  (rx_err_bad_frame_pulse),
        .rx_error_bad_fcs    (rx_err_bad_fcs_pulse),
        .rx_fifo_overflow    (),
        .rx_fifo_bad_frame   (),
        .rx_fifo_good_frame  (rx_good_frame_pulse), // ★ 扫描器判据
        .speed               (link_speed),

        // 配置端口 (新版 MAC 改名: ifg_delay → cfg_ifg)
        .cfg_ifg             (8'd12),
        .cfg_tx_enable       (1'b1),
        .cfg_rx_enable       (1'b1)
    );

    assign link_up = phy_ready & (link_speed == 2'b10);

    // -------------------------------------------------------------------------
    // 12) RX 诊断信号脉冲拉宽 (125 MHz 域 → 65 MHz LED 域 跨时钟用)
    //     窄脉冲 (1 周期 @ 125 MHz = 8 ns) 直接给慢时钟会漏, 这里拉到 ~ µs 级.
    //
    //     - rx_err_bad_fcs_pulse  : MAC 报告该帧 CRC 错误 (在 §11 上方已声明)
    //     - rx_err_bad_frame_pulse: MAC 报告该帧整体不合法
    //     - rx_axis_tvalid        : MAC 输出 AXIS 上有 RX 数据 (任意帧)
    // -------------------------------------------------------------------------
    reg [4:0]  rx_err_fcs_cnt   = 5'd0;
    reg [4:0]  rx_err_frame_cnt = 5'd0;
    reg [11:0] rx_act_cnt       = 12'd0;

    always @(posedge clk125) begin
        if (rst125) begin
            rx_err_fcs_cnt   <= 5'd0;
            rx_err_frame_cnt <= 5'd0;
            rx_act_cnt       <= 12'd0;
        end else begin
            if (rx_err_bad_fcs_pulse)
                rx_err_fcs_cnt <= 5'h1F;
            else if (rx_err_fcs_cnt != 0)
                rx_err_fcs_cnt <= rx_err_fcs_cnt - 1'b1;

            if (rx_err_bad_frame_pulse)
                rx_err_frame_cnt <= 5'h1F;
            else if (rx_err_frame_cnt != 0)
                rx_err_frame_cnt <= rx_err_frame_cnt - 1'b1;

            // 拉到 ~32 µs (4096 / 125 MHz), 65 MHz 慢时钟肯定能采到
            if (rx_axis_tvalid)
                rx_act_cnt <= 12'hFFF;
            else if (rx_act_cnt != 0)
                rx_act_cnt <= rx_act_cnt - 1'b1;
        end
    end

    assign rx_error_bad_fcs   = (rx_err_fcs_cnt   != 0);
    assign rx_error_bad_frame = (rx_err_frame_cnt != 0);
    assign rx_frame_activity  = (rx_act_cnt       != 0);

    // -------------------------------------------------------------------------
    // 13) 引脚级 eth_rxctl 活动检测 (绕开 MAC, 直接判断 RX 物理信号是否活着)
    //
    //     eth_rxctl 在 PHY 输出端是 RXC 同步, 频率随负载波动. 我们只关心
    //     "它有没有跳变", 不关心精确采样. 用 clk125 异步采样 + 边沿检测 +
    //     脉冲拉宽到 ~ms 级, 就能从 LED 直观看出引脚是否活着.
    //
    //     这是判断 "PHY 究竟有没有给 FPGA 送数据" 的最关键诊断信号.
    //     若 LED 不亮, 物理层就有问题; 若 LED 亮, 问题在 MAC 时序/采样.
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [2:0] rxctl_sync = 3'd0;
    reg [23:0] rxctl_act_cnt = 24'd0;

    always @(posedge clk125) begin
        rxctl_sync <= {rxctl_sync[1:0], eth_rxctl};
        if (rst125)
            rxctl_act_cnt <= 24'd0;
        else if (rxctl_sync[2] != rxctl_sync[1])
            // 任意一次跳变, 灯亮 ~13 ms (1.6M / 125MHz)
            rxctl_act_cnt <= 24'd1_600_000;
        else if (rxctl_act_cnt != 0)
            rxctl_act_cnt <= rxctl_act_cnt - 1'b1;
    end

    assign rxctl_pin_activity = (rxctl_act_cnt != 0);

    // -------------------------------------------------------------------------
    // 14) 引脚级 eth_rxd[3:0] 每位独立活动检测
    //
    //     若某 RXD 位 PCB 短路 / 卡死 / 走线断开, 它就永远不跳变. 而其他位
    //     可能正常跳变, 此时单纯的 RXCTL 检测看不出来. 这里给每个 RXD 位
    //     独立做边沿检测, 输出每位是否活动 + 全部都活动的 AND 信号.
    //
    //     若 rxd_all_active = 0 但 rxctl_pin_activity = 1, 说明至少一位
    //     RXD 死了 (查看 rxd_per_bit_active 知道是哪位).
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg [3:0] rxd_sync_a = 4'd0;
    (* ASYNC_REG = "TRUE" *) reg [3:0] rxd_sync_b = 4'd0;
    reg [23:0] rxd0_cnt = 24'd0;
    reg [23:0] rxd1_cnt = 24'd0;
    reg [23:0] rxd2_cnt = 24'd0;
    reg [23:0] rxd3_cnt = 24'd0;

    always @(posedge clk125) begin
        rxd_sync_a <= eth_rxd;
        rxd_sync_b <= rxd_sync_a;

        if (rst125) begin
            rxd0_cnt <= 24'd0;
            rxd1_cnt <= 24'd0;
            rxd2_cnt <= 24'd0;
            rxd3_cnt <= 24'd0;
        end else begin
            // RXD0
            if (rxd_sync_a[0] != rxd_sync_b[0])
                rxd0_cnt <= 24'd1_600_000;
            else if (rxd0_cnt != 0)
                rxd0_cnt <= rxd0_cnt - 1'b1;
            // RXD1
            if (rxd_sync_a[1] != rxd_sync_b[1])
                rxd1_cnt <= 24'd1_600_000;
            else if (rxd1_cnt != 0)
                rxd1_cnt <= rxd1_cnt - 1'b1;
            // RXD2
            if (rxd_sync_a[2] != rxd_sync_b[2])
                rxd2_cnt <= 24'd1_600_000;
            else if (rxd2_cnt != 0)
                rxd2_cnt <= rxd2_cnt - 1'b1;
            // RXD3
            if (rxd_sync_a[3] != rxd_sync_b[3])
                rxd3_cnt <= 24'd1_600_000;
            else if (rxd3_cnt != 0)
                rxd3_cnt <= rxd3_cnt - 1'b1;
        end
    end

    assign rxd_per_bit_active = {rxd3_cnt != 0, rxd2_cnt != 0,
                                 rxd1_cnt != 0, rxd0_cnt != 0};
    assign rxd_all_active     = (rxd0_cnt != 0) & (rxd1_cnt != 0)
                              & (rxd2_cnt != 0) & (rxd3_cnt != 0);

    // -------------------------------------------------------------------------
    // 14.5) 协议层活动指示 (★ 都聚焦到 ARP ★)
    //
    //   rx_eth_hdr_activity = 收到 ethertype=0x0806 (ARP) 且 dst=广播 或 本机
    //     LED 闪 = PC 的 ARP 请求真的到了 FPGA
    //     LED 灭 = 收到的不是 ARP / 不是发给我的
    //
    //   tx_axis_activity    = ★ 改: 只在 FPGA 输出 ethertype=0x0806 (ARP 响应)
    //     LED 闪 = FPGA 在产生 ARP 响应 (问题在 PHY 物理 TX 层)
    //     LED 灭 = FPGA 没产生 ARP 响应 (ARP 模块没识别请求)
    //
    //   组合判读 (ping 状态下):
    //     LED1 闪 + LED2 闪 → ★ ARP 协议层 OK, 100% 是 PHY 物理层 TX 问题 ★
    //     LED1 闪 + LED2 灭 → ARP 没回, LOCAL_IP 配置或 ARP 模块 bug
    //     LED1 灭 + LED2 灭 → 收到的不是 ARP (PC 路由问题, 但 Wireshark 看到了 ARP, 矛盾...)
    // -------------------------------------------------------------------------
    wire arp_for_us = rx_eth_hdr_valid && rx_eth_hdr_ready
                   && (rx_eth_type == 16'h0806)
                   && ((rx_eth_dest_mac == 48'hFFFFFFFFFFFF)
                    || (rx_eth_dest_mac == LOCAL_MAC));

    wire arp_tx = tx_eth_hdr_valid && tx_eth_hdr_ready
               && (tx_eth_type == 16'h0806);

    reg [22:0] rx_hdr_act_cnt  = 23'd0;
    reg [22:0] tx_axis_act_cnt = 23'd0;
    localparam ACT_RELOAD = 23'd6_250_000;  // 50 ms @ 125 MHz

    always @(posedge clk125) begin
        if (rst125) begin
            rx_hdr_act_cnt  <= 23'd0;
            tx_axis_act_cnt <= 23'd0;
        end else begin
            // ★ 只在 ARP 请求帧时点亮 ★
            if (arp_for_us)
                rx_hdr_act_cnt <= ACT_RELOAD;
            else if (rx_hdr_act_cnt != 0)
                rx_hdr_act_cnt <= rx_hdr_act_cnt - 1'b1;

            // ★ 只在 ARP 响应 (TX) 时点亮 ★
            if (arp_tx)
                tx_axis_act_cnt <= ACT_RELOAD;
            else if (tx_axis_act_cnt != 0)
                tx_axis_act_cnt <= tx_axis_act_cnt - 1'b1;
        end
    end

    assign rx_eth_hdr_activity = (rx_hdr_act_cnt  != 0);
    assign tx_axis_activity    = (tx_axis_act_cnt != 0);

    // -------------------------------------------------------------------------
    // 15) IDELAY 自动扫描状态机 (RX_IDELAY_AUTO=1 时生效) ★ 加固版 ★
    //
    //  策略 (v2): 上电后从 tap=0 开始, 每个 tap 停留 ~1.5 秒, 必须在该窗口
    //        内收到 ★ 至少 MIN_GOOD_FRAMES 个 完整且无 CRC 错的 帧 ★
    //        才锁定. 这样可以筛掉"临界 tap"(只能勉强收 1 帧, 之后采样窗口
    //        漂出而失效).
    //
    //  关键参数:
    //     SCAN_DWELL_CYC   = 1.5 s/tap (覆盖 1+ 个 ARP 周期, PC ping 间隔 1s)
    //     MIN_GOOD_FRAMES  = 3 (临界 tap 一般只能收 1 个, 中心 tap 能收 1+ 帧)
    //     总扫描时间       = 32 × 1.5 ≈ 48 秒 (上电后请耐心等)
    //
    //  注意: 必须用 rx_fifo_good_frame 当判据 (CRC 校验通过的完整帧),
    //        rx_axis_tvalid 噪声也会触发, 不可靠.
    //
    //  调通后, 看 idelay_scan_tap_now 的值, 改 RX_IDELAY_AUTO=0,
    //  RX_IDELAY_TAP=<那个值>, 节省启动时间.
    // -------------------------------------------------------------------------
    localparam SCAN_DWELL_CYC   = 32'd187_500_000;  // 1.5 s @ 125 MHz
    localparam MIN_GOOD_FRAMES  = 3;

    generate
    if (RX_IDELAY_AUTO != 0) begin : g_scan
        reg [4:0]  scan_tap     = 5'd0;
        reg [31:0] scan_dwell   = 32'd0;
        reg [3:0]  scan_seen_n  = 4'd0;          // 当前 tap 收到的 GOOD 帧累计
        reg        scan_locked_r= 1'b0;
        reg        scan_failed_r= 1'b0;
        reg        scan_load_r  = 1'b0;
        // settle: tap 切换后给 MAC ~10ms 缓冲, 期间不计数
        reg [31:0] scan_settle  = 32'd0;
        localparam SCAN_SETTLE_CYC = 32'd1_250_000;  // 10 ms @ 125 MHz

        always @(posedge clk125) begin
            scan_load_r <= 1'b0;  // 默认 0, 单周期脉冲
            if (rst125 || !phy_ready) begin
                scan_tap      <= 5'd0;
                scan_dwell    <= 32'd0;
                scan_settle   <= SCAN_SETTLE_CYC;
                scan_seen_n   <= 4'd0;
                scan_locked_r <= 1'b0;
                scan_failed_r <= 1'b0;
                scan_load_r   <= 1'b1;   // 把 tap=0 加载进去
            end else if (scan_locked_r) begin
                // 已经锁定, 不再变更
            end else begin
                if (scan_settle != 0) begin
                    scan_settle <= scan_settle - 1'b1;
                end else begin
                    // 在 dwell 窗口内累加 GOOD 帧数 (饱和到 4'b1111)
                    if (rx_good_frame_pulse && (scan_seen_n != 4'hF))
                        scan_seen_n <= scan_seen_n + 4'd1;

                    if (scan_dwell < SCAN_DWELL_CYC) begin
                        scan_dwell <= scan_dwell + 1'b1;
                    end else begin
                        // dwell 完成, 判定: 必须收到 ≥ MIN_GOOD_FRAMES 才算
                        if (scan_seen_n >= MIN_GOOD_FRAMES) begin
                            scan_locked_r <= 1'b1;   // 找到稳定 tap
                        end else if (scan_tap == 5'd31) begin
                            scan_failed_r <= 1'b1;   // 32 个都试过都不稳
                            scan_locked_r <= 1'b1;   // 锁住, 不再扫
                        end else begin
                            scan_tap    <= scan_tap + 5'd1;
                            scan_load_r <= 1'b1;
                            scan_settle <= SCAN_SETTLE_CYC;
                        end
                        scan_dwell  <= 32'd0;
                        scan_seen_n <= 4'd0;
                    end
                end
            end
        end

        assign idelay_tap_cur     = scan_tap;
        assign idelay_load        = scan_load_r;
        assign idelay_scan_locked = scan_locked_r & ~scan_failed_r;
        assign idelay_scan_failed = scan_failed_r;
        assign idelay_scan_tap_now= scan_tap;
    end else begin : g_fixed
        // 固定模式: tap 永远是 RX_IDELAY_TAP, 不动
        reg loaded = 1'b0;
        reg load_pulse = 1'b0;
        always @(posedge clk125) begin
            load_pulse <= 1'b0;
            if (rst125) begin
                loaded     <= 1'b0;
            end else if (!loaded) begin
                load_pulse <= 1'b1;
                loaded     <= 1'b1;
            end
        end
        assign idelay_tap_cur     = RX_IDELAY_TAP[4:0];
        assign idelay_load        = load_pulse;
        assign idelay_scan_locked = 1'b1;
        assign idelay_scan_failed = 1'b0;
        assign idelay_scan_tap_now= RX_IDELAY_TAP[4:0];
    end
    endgenerate

endmodule
