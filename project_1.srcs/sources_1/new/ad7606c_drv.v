`timescale 1ns / 1ps
// =============================================================================
//  ad7606c_drv.v  ─── AD7606C-16 并口驱动 (8 通道 / 16 bit / 最高 1 MSPS)
//
//  用户接口沿用小梅哥 Ad7606_driver 的风格:
//    go / speed_set / conv_done / data_flag / data_mult_ch / data1..data8
//  针对 AD7606C-16 (而非老款 AD7606) 的差异:
//    1) 软件模式 (OS=111): 上电后经并口写寄存器, 打开 220 kHz 高带宽、设置量程,
//       并回读 ID(0x2F) 与 BANDWIDTH(0x07) 自检.  硬件模式 (SOFT_MODE=0) 下
//       OS=000, 不写寄存器, 带宽固定 25 kHz, 仅用于低频接线验证.
//    2) 模块 P3 上的 "CONVSTB" 实为 WR (芯片 pin10), 只在写寄存器时拉低;
//       模块上短接 CONVSTA/CONVSTB 的跳线 H5 必须拔掉.
//    3) 上电完全复位 (RESET 高 >= 3.2 us), 之后等待 tDEVICE_SETUP >= 274 us;
//       软/硬件模式与并/串口在完全复位释放时锁存, 所以 OS 引脚从上电起就固定输出.
//    4) BUSY 下降沿后连续 8 次 RD 读 V1..V8, 允许延续到下一次转换
//       ("Reading During Conversion"), 1 MSPS 下读数时间才够.
//    5) data1..data8 在 8 路全部读完后同拍更新, 保证下游看到的是同一采样时刻.
//
//  数据手册时序 (Table 3/4, VDRIVE = 3.3 V):
//    tCYCLE >= 1 us, tCONV = 0.5~0.65 us, tD_CNV_BSY <= 22 ns
//    tD_CS_DB <= 35 ns, tD_RD_DB <= 30 ns, tLP_RD/tHP_RD >= 10 ns, tCYC_RD >= 30 ns
//    tD_BSY >= 25 ns (最后一个 RD 下降沿 → 下一个 BUSY 下降沿)
//    tLP_WR >= 35 ns, tCYC_WR >= 180 ns, tS_DB_WR / tH_WR_DB >= 5 ns
//
//  65 MHz 下 1 MSPS 的读数窗口 (RD_LOW_CYC=5, RD_HIGH_CYC=1 → 仍 8×6 拍):
//    BUSY 下降沿约在 CONVST 后 33~44 拍; 同步 3 拍 + 毛刺滤波 1 拍 + CS 1 拍 + 8×6 拍 RD,
//    最坏约第 97 拍结束, 早于下一次 BUSY 下降沿 (>= 第 98 拍).
//    2026-10-29: 示波器偶发 ~1.9 V (悬空通道偏置) → 加大 RD 低电平余量 + BUSY 滤波,
//    FRSTDATA 错位的当次采样不发布 (见 docs/handbook/09_AD7606C读数错位与修复.md).
// =============================================================================

module ad7606c_drv #(
    parameter integer CLK_HZ      = 65_000_000,
    parameter integer SOFT_MODE   = 1,       // 1: 软件模式 (寄存器配置)  0: 硬件模式
    parameter [7:0]   REG_BW      = 8'hFF,   // 0x07 BANDWIDTH, bit0=CH1 .. bit7=CH8, 1=220 kHz
    parameter [7:0]   REG_RANGE12 = 8'h33,   // 0x03 [7:4]=CH2 [3:0]=CH1; 0011=±10 V, 0001=±5 V 单端
    parameter [7:0]   REG_RANGE34 = 8'h33,   // 0x04
    parameter [7:0]   REG_RANGE56 = 8'h33,   // 0x05
    parameter [7:0]   REG_RANGE78 = 8'h33,   // 0x06
    // RD 低加长、高缩短: 总周期仍 6 拍, 不挤占下一轮 BUSY↓; 低电平给飞线更多建立时间
    parameter integer RD_LOW_CYC  = 5,       // RD 低电平拍数 (>= tD_RD_DB + IO 延迟), 原 4
    parameter integer RD_HIGH_CYC = 1,       // RD 高电平拍数 (>= tHP_RD=10 ns → 1 拍够), 原 2
    parameter integer BUSY_LOW_STABLE = 2,   // 同步后连续低这么多拍才认 BUSY↓ (抑制毛刺)
    parameter integer PWRUP_US    = 10_000,  // 上电等待 (tPOWER-UP 10 ms)
    parameter integer RESET_US    = 4,       // 完全复位脉宽 (>= 3.2 us)
    parameter integer SETUP_US    = 300      // 复位释放后等待 (tDEVICE_SETUP >= 274 us)
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 用户控制 ----
    input  wire        go,           // 1: 连续采样; 0: 停发 CONVST
    input  wire [15:0] speed_set,    // CONVST 周期 = speed_set + 1 拍 (不足 1 us 时按 1 us)
    // 运行时改 CH3/CH4 (V3/V4) 量程: 寄存器 0x04 = {CH4[7:4], CH3[3:0]}
    //   码: 0=±2.5 1=±5 2=±6.25 3=±10 4=±12.5 V 单端; 详见 AD7606C 手册
    input  wire        range34_we,   // 一拍: 装载 range34_wdata 并触发重配
    input  wire [7:0]  range34_wdata,
    output reg  [7:0]  range34_r,    // 当前已生效的 RANGE34

    // ---- 结果输出 ----
    output reg         conv_done,    // 8 路读完, data1..8 已更新 (单拍)
    output reg  [7:0]  data_flag,    // 第 k 路读到时 bit k 出一拍 (配合 data_mult_ch)
    output reg  [15:0] data_mult_ch, // 分时输出的单路结果
    output reg  [15:0] data1, data2, data3, data4,
    output reg  [15:0] data5, data6, data7, data8,

    // ---- 状态 ----
    output reg         cfg_done,     // 上电配置完成, 进入连续采样
    output reg         cfg_err,      // ID 或 BANDWIDTH 回读不符
    output reg  [7:0]  dev_id,       // 0x2F 回读值 (AD7606C-16 应为 0x31)
    output reg         frst_err,     // FRSTDATA 与通道序号不一致 (粘滞)

    // ---- AD7606C 引脚 ----
    inout  wire [15:0] ad_db,
    output reg         ad_convst,
    output reg         ad_wr_n,
    output reg         ad_rd_n,
    output reg         ad_cs_n,
    output reg         ad_reset,
    output wire [2:0]  ad_os,
    input  wire        ad_busy,
    input  wire        ad_frstdata
);

localparam integer CYC_PER_US = CLK_HZ / 1_000_000;
localparam integer PWRUP_CYC  = PWRUP_US * CYC_PER_US;
localparam integer RESET_CYC  = RESET_US * CYC_PER_US;
localparam integer SETUP_CYC  = SETUP_US * CYC_PER_US;
localparam integer MIN_PERIOD = (CLK_HZ + 999_999) / 1_000_000;   // tCYCLE >= 1 us
localparam integer RD_PERIOD  = RD_LOW_CYC + RD_HIGH_CYC;
localparam integer CONVST_HI  = 8;
localparam integer BUSY_LOW_NEED = (BUSY_LOW_STABLE > 0) ? (BUSY_LOW_STABLE - 1) : 0;
localparam integer RANGE_SETTLE_CYC = 100 * CYC_PER_US;  // 量程切换后约 100 us 再恢复 CONVST

assign ad_os = (SOFT_MODE != 0) ? 3'b111 : 3'b000;

// ---- 双向数据总线 ----
reg         db_oe;
reg  [15:0] db_out;
assign ad_db = db_oe ? db_out : 16'bz;

(* IOB = "TRUE" *) reg [15:0] db_in_r;
(* IOB = "TRUE" *) reg        frst_in_r;
reg [2:0] busy_s;
reg       busy_seen_high;                 // 同步域里见过 BUSY=1
reg [2:0] busy_low_cnt;                   // 见过后连续为低的拍数
reg       busy_fall;                      // 单拍: 干净的 BUSY 下降
always @(posedge clk) begin
    db_in_r   <= ad_db;
    frst_in_r <= ad_frstdata;
    busy_s    <= {busy_s[1:0], ad_busy};

    // BUSY 毛刺滤波: 必须先见高, 再连续 BUSY_LOW_STABLE 拍为低, 才启动读数.
    // 飞线上的窄毛刺不会同时满足“曾为高 + 连续稳定为低”.
    busy_fall <= 1'b0;
    if (!rst_n) begin
        busy_seen_high <= 1'b0;
        busy_low_cnt   <= 3'd0;
    end else if (busy_s[2]) begin
        busy_seen_high <= 1'b1;
        busy_low_cnt   <= 3'd0;
    end else if (busy_seen_high) begin
        if (busy_low_cnt >= BUSY_LOW_NEED) begin
            busy_fall      <= 1'b1;
            busy_seen_high <= 1'b0;
            busy_low_cnt   <= 3'd0;
        end else
            busy_low_cnt <= busy_low_cnt + 3'd1;
    end
end

// ---- 上电配置命令表 (并口寄存器读写, DB15=R/W, DB14:8=地址, DB7:0=数据) ----
localparam integer N_OPS = 10;
reg  [3:0]  op_idx;
reg         op_is_rd;
reg  [15:0] op_word;
always @(*) begin
    op_is_rd = 1'b0;
    case (op_idx)
        4'd0: op_word = {1'b1, 7'h2F, 8'h00};         // 读命令 ID → 进入寄存器模式
        4'd1: begin op_word = 16'h0000; op_is_rd = 1'b1; end
        4'd2: op_word = {1'b0, 7'h07, REG_BW};
        4'd3: op_word = {1'b0, 7'h03, REG_RANGE12};
        4'd4: op_word = {1'b0, 7'h04, range34_r};     // 可被 RNG3/RNG4 运行时更新
        4'd5: op_word = {1'b0, 7'h05, REG_RANGE56};
        4'd6: op_word = {1'b0, 7'h06, REG_RANGE78};
        4'd7: op_word = {1'b1, 7'h07, 8'h00};         // 读命令 BANDWIDTH
        4'd8: begin op_word = 16'h0000; op_is_rd = 1'b1; end
        default: op_word = 16'h0000;                  // 全 0 写 → 回到 ADC 模式
    endcase
end

// ---- 主状态机 ----
localparam [2:0] ST_PWRUP  = 3'd0,
                 ST_RESET  = 3'd1,
                 ST_SETUP  = 3'd2,
                 ST_CFG    = 3'd3,
                 ST_RUN    = 3'd4,
                 ST_RECFG  = 3'd5,   // 运行中改写 RANGE34
                 ST_RSETTLE= 3'd6;   // 量程切换后等待稳定

reg [2:0]  state;
reg [31:0] wait_cnt;
reg [3:0]  op_ph;          // 每条配置命令 16 拍
reg        range_pend;     // 有待处理的量程更新
reg [15:0] recfg_word;     // ST_RECFG 当前写总线字
reg        recfg_last;     // 1 = 本条是退出寄存器模式的全 0 写

reg [15:0] cnv_cnt;
wire [15:0] period = ({1'b0, speed_set} + 17'd1 < MIN_PERIOD) ? MIN_PERIOD[15:0]
                                                               : speed_set + 16'd1;

reg        rd_pend, rd_act, done_pend;
reg [2:0]  rd_ch;
reg [3:0]  rd_ph;
reg [15:0] sh0, sh1, sh2, sh3, sh4, sh5, sh6, sh7;
reg        frst_bad_shot;   // 本轮 8 通道读数中出现过 FRSTDATA 错位

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= ST_PWRUP;
        wait_cnt   <= 32'd0;
        op_idx     <= 4'd0;
        op_ph      <= 4'd0;
        cnv_cnt    <= 16'd0;
        ad_convst  <= 1'b0;
        ad_wr_n    <= 1'b1;
        ad_rd_n    <= 1'b1;
        ad_cs_n    <= 1'b1;
        ad_reset   <= 1'b0;
        db_oe      <= 1'b0;
        db_out     <= 16'h0000;
        rd_pend    <= 1'b0;
        rd_act     <= 1'b0;
        done_pend  <= 1'b0;
        rd_ch      <= 3'd0;
        rd_ph      <= 4'd0;
        frst_bad_shot <= 1'b0;
        conv_done  <= 1'b0;
        data_flag  <= 8'd0;
        data_mult_ch <= 16'd0;
        {data1, data2, data3, data4} <= 64'd0;
        {data5, data6, data7, data8} <= 64'd0;
        {sh0, sh1, sh2, sh3} <= 64'd0;
        {sh4, sh5, sh6, sh7} <= 64'd0;
        cfg_done   <= 1'b0;
        cfg_err    <= 1'b0;
        dev_id     <= 8'd0;
        frst_err   <= 1'b0;
        range34_r  <= REG_RANGE34;
        range_pend <= 1'b0;
        recfg_word <= 16'd0;
        recfg_last <= 1'b0;
    end else begin
        conv_done <= 1'b0;
        data_flag <= 8'd0;

        // 任意状态都可锁存量程请求 (在 ST_RUN 空闲时执行)
        if (range34_we) begin
            range34_r  <= range34_wdata;
            range_pend <= 1'b1;
        end

        case (state)
        // ---------------------------------------------------------------
        ST_PWRUP: begin
            if (wait_cnt >= PWRUP_CYC - 1) begin
                wait_cnt <= 32'd0;
                ad_reset <= 1'b1;
                state    <= ST_RESET;
            end else
                wait_cnt <= wait_cnt + 32'd1;
        end
        // ---------------------------------------------------------------
        ST_RESET: begin
            if (wait_cnt >= RESET_CYC - 1) begin
                wait_cnt <= 32'd0;
                ad_reset <= 1'b0;
                state    <= ST_SETUP;
            end else
                wait_cnt <= wait_cnt + 32'd1;
        end
        // ---------------------------------------------------------------
        ST_SETUP: begin
            if (wait_cnt >= SETUP_CYC - 1) begin
                wait_cnt <= 32'd0;
                op_idx   <= 4'd0;
                op_ph    <= 4'd0;
                if (SOFT_MODE != 0)
                    state <= ST_CFG;
                else begin
                    cfg_done <= 1'b1;
                    cnv_cnt  <= 16'd0;
                    state    <= ST_RUN;
                end
            end else
                wait_cnt <= wait_cnt + 32'd1;
        end
        // ---------------------------------------------------------------
        // 每条命令 16 拍: ph0 CS↓(写: 驱动总线) / ph1 WR↓或RD↓ / ph6 WR↑或RD↑
        //   (读: 此拍采样, RD 已低 4 拍) / ph7 CS↑ 释放总线 / ph8..15 空闲
        //   → WR 低 5 拍 77 ns, WR↑ 到下一 WR↑ 16 拍 246 ns
        ST_CFG: begin
            op_ph <= op_ph + 4'd1;
            case (op_ph)
                4'd0: begin
                    ad_cs_n <= 1'b0;
                    if (!op_is_rd) begin
                        db_oe  <= 1'b1;
                        db_out <= op_word;
                    end
                end
                4'd1: begin
                    if (op_is_rd) ad_rd_n <= 1'b0;
                    else          ad_wr_n <= 1'b0;
                end
                4'd6: begin
                    ad_rd_n <= 1'b1;
                    ad_wr_n <= 1'b1;
                    if (op_is_rd) begin
                        if (op_idx == 4'd1) begin
                            dev_id <= db_in_r[7:0];
                            if (db_in_r[7:4] != 4'h3 || db_in_r[14:8] != 7'h2F)
                                cfg_err <= 1'b1;
                        end else if (db_in_r[7:0] != REG_BW)
                            cfg_err <= 1'b1;
                    end
                end
                4'd7: begin
                    ad_cs_n <= 1'b1;
                    db_oe   <= 1'b0;
                end
                4'd15: begin
                    if (op_idx == N_OPS - 1) begin
                        cfg_done <= 1'b1;
                        cnv_cnt  <= 16'd0;
                        state    <= ST_RUN;
                    end else
                        op_idx <= op_idx + 4'd1;
                end
                default: ;
            endcase
        end
        // ---------------------------------------------------------------
        ST_RUN: begin
            // 量程更新: 等本轮读数结束再进寄存器写, 并暂停新 CONVST
            if (range_pend && !rd_act && !rd_pend && !done_pend) begin
                range_pend <= 1'b0;
                ad_convst  <= 1'b0;
                cnv_cnt    <= 16'd0;
                op_ph      <= 4'd0;
                recfg_last <= 1'b0;
                recfg_word <= {1'b0, 7'h04, (range34_we ? range34_wdata : range34_r)};
                state      <= ST_RECFG;
            end else begin

            // CONVST: 每 period 拍一个上升沿, 高 CONVST_HI 拍
            if (cnv_cnt >= period - 16'd1)
                cnv_cnt <= 16'd0;
            else
                cnv_cnt <= cnv_cnt + 16'd1;

            if (cnv_cnt == 16'd0 && go && !range_pend)
                ad_convst <= 1'b1;
            else if (cnv_cnt == CONVST_HI)
                ad_convst <= 1'b0;

            // 干净的 BUSY↓ → CS↓, 下一拍开始 8 次 RD
            if (busy_fall && !rd_act && !rd_pend && !range_pend) begin
                ad_cs_n <= 1'b0;
                rd_pend <= 1'b1;
            end

            if (rd_pend) begin
                rd_pend       <= 1'b0;
                rd_act        <= 1'b1;
                rd_ch         <= 3'd0;
                rd_ph         <= 4'd0;
                frst_bad_shot <= 1'b0;
                ad_rd_n       <= 1'b0;
            end

            if (rd_act) begin
                if (rd_ph == RD_LOW_CYC - 1)
                    ad_rd_n <= 1'b1;

                // RD 已低 RD_LOW_CYC 拍时的总线采样
                if (rd_ph == RD_LOW_CYC) begin
                    data_mult_ch <= db_in_r;
                    data_flag    <= 8'd1 << rd_ch;
                    // FRSTDATA 仅在读 V1 时为高; 错位则粘滞告警, 本轮不发布
                    if (frst_in_r != (rd_ch == 3'd0)) begin
                        frst_err      <= 1'b1;
                        frst_bad_shot <= 1'b1;
                    end
                    case (rd_ch)
                        3'd0: sh0 <= db_in_r;
                        3'd1: sh1 <= db_in_r;
                        3'd2: sh2 <= db_in_r;
                        3'd3: sh3 <= db_in_r;
                        3'd4: sh4 <= db_in_r;
                        3'd5: sh5 <= db_in_r;
                        3'd6: sh6 <= db_in_r;
                        default: sh7 <= db_in_r;
                    endcase
                end

                if (rd_ph == RD_PERIOD - 1) begin
                    rd_ph <= 4'd0;
                    if (rd_ch == 3'd7) begin
                        rd_act    <= 1'b0;
                        ad_cs_n   <= 1'b1;
                        done_pend <= 1'b1;
                    end else begin
                        rd_ch   <= rd_ch + 3'd1;
                        ad_rd_n <= 1'b0;
                    end
                end else
                    rd_ph <= rd_ph + 4'd1;
            end

            if (done_pend) begin
                done_pend <= 1'b0;
                // 本轮 FRSTDATA 异常: 保持上一组 data1..8, 不拉 conv_done,
                // 避免示波器 / 锁相链吃进错位的悬空通道码 (~1.9 V)
                if (!frst_bad_shot) begin
                    conv_done <= 1'b1;
                    data1 <= sh0;  data2 <= sh1;  data3 <= sh2;  data4 <= sh3;
                    data5 <= sh4;  data6 <= sh5;  data7 <= sh6;  data8 <= sh7;
                end
            end
            end // !range_pend entry
        end
        // ---------------------------------------------------------------
        // 运行中写 RANGE34: 写 0x04 → 写 0x0000 退出寄存器模式
        ST_RECFG: begin
            op_ph <= op_ph + 4'd1;
            case (op_ph)
                4'd0: begin
                    ad_cs_n <= 1'b0;
                    db_oe   <= 1'b1;
                    db_out  <= recfg_word;
                end
                4'd1: ad_wr_n <= 1'b0;
                4'd6: ad_wr_n <= 1'b1;
                4'd7: begin
                    ad_cs_n <= 1'b1;
                    db_oe   <= 1'b0;
                end
                4'd15: begin
                    if (!recfg_last) begin
                        recfg_last <= 1'b1;
                        recfg_word <= 16'h0000;
                        op_ph      <= 4'd0;
                    end else begin
                        wait_cnt <= 32'd0;
                        state    <= ST_RSETTLE;
                    end
                end
                default: ;
            endcase
        end
        // ---------------------------------------------------------------
        ST_RSETTLE: begin
            if (wait_cnt >= RANGE_SETTLE_CYC - 1) begin
                wait_cnt <= 32'd0;
                cnv_cnt  <= 16'd0;
                state    <= ST_RUN;
            end else
                wait_cnt <= wait_cnt + 32'd1;
        end
        default: state <= ST_PWRUP;
        endcase
    end
end

endmodule
