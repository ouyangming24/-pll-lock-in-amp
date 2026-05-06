`timescale 1ns / 1ps
// =============================================================================
//  eth_phy_init.v
//
//  RTL8211E 上电复位 + (可选) MDIO 配置
//
//  作用:
//      1) 板子上电后, 给 PHY 拉一段 PHY_RST_LOW_MS 的硬复位
//      2) 复位释放后等 PHY_INIT_WAIT_MS 让 PHY 内部自检完成
//      3) 期间一直拉低 phy_ready (内部 ready), 阻止 MAC 早发包
//
//  关于 RGMII 内部延迟:
//      RTL8211E 默认就开启了 RX/TX 时钟相对数据 2 ns 的内部延迟,
//      所以一般 *不需要* 通过 MDIO 重新配置. FPGA 端也就不用 IDELAY.
//      如果实测有 CRC 错, 再考虑加 MDIO 写过程或 FPGA 端 IDELAY.
//
//  ETH_INTB / ETH_MDIO / ETH_MDC 可悬空 (本模块用不到).
// =============================================================================
module eth_phy_init #(
    parameter integer CLK_FREQ_HZ    = 125_000_000,
    parameter integer PHY_RST_LOW_MS = 20,    // 拉低复位时长 (RTL8211E 要 ≥10 ms)
    parameter integer PHY_INIT_WAIT_MS = 200  // 释放后稳定等待 (≥150 ms 推荐)
)(
    input  wire clk,        // 任意稳定时钟即可, 这里用 125 MHz
    input  wire rst,        // 同步高有效复位
    output reg  phy_rst_n,  // 直接接 PHY 的硬复位脚 (低有效)
    output reg  phy_ready   // 高电平表示 PHY 已就绪, MAC 可工作
);

    localparam integer LOW_TICKS  = (CLK_FREQ_HZ/1000) * PHY_RST_LOW_MS;
    localparam integer WAIT_TICKS = (CLK_FREQ_HZ/1000) * PHY_INIT_WAIT_MS;

    localparam S_RST  = 2'd0;
    localparam S_WAIT = 2'd1;
    localparam S_RUN  = 2'd2;

    reg [1:0]  state;
    reg [27:0] cnt;     // 28 bit 足够计 2 秒 @ 125 MHz

    always @(posedge clk) begin
        if (rst) begin
            state     <= S_RST;
            cnt       <= 28'd0;
            phy_rst_n <= 1'b0;
            phy_ready <= 1'b0;
        end else begin
            case (state)
            S_RST: begin
                phy_rst_n <= 1'b0;
                phy_ready <= 1'b0;
                if (cnt >= LOW_TICKS-1) begin
                    cnt   <= 28'd0;
                    state <= S_WAIT;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end

            S_WAIT: begin
                phy_rst_n <= 1'b1;
                phy_ready <= 1'b0;
                if (cnt >= WAIT_TICKS-1) begin
                    cnt   <= 28'd0;
                    state <= S_RUN;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end

            S_RUN: begin
                phy_rst_n <= 1'b1;
                phy_ready <= 1'b1;
            end

            default: state <= S_RST;
            endcase
        end
    end

endmodule
