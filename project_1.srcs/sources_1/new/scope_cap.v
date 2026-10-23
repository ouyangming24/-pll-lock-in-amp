`timescale 1ns / 1ps
// =============================================================================
//  scope_cap.v  ─── 双通道示波器抓取 (AD7606C V5/V6, 最高 1 MSPS)
//
//  arm 一拍后开始连续写环形缓存: 先攒满 PRE 点预触发, 再等触发条件;
//  触发样点之后再写 N-PRE-1 点即完成 (done=1, 保持到 clear 或下一次 arm).
//  读口按时间顺序编址: rd_idx = 0..N-1, 触发样点位于 rd_idx = PRE; 读延迟 2 拍.
//
//  trig_mode : 0 = 立即 (不等触发)
//              1 = A 上升沿  2 = A 下降沿  3 = B 上升沿  4 = B 下降沿
//  auto_en   : 1 = 等待超过 max(100 ms, 一屏时长) 仍无触发则强制触发 (forced=1)
//              0 = 一直等到真实触发 (正常模式)
//  decim     : 每 decim+1 个 ADC 样点存 1 点 (0 = 不抽取)
//  触发带 HYST 迟滞: 上升沿须先低于 level-HYST 再升到 ≥ level 才算一次触发
// =============================================================================
module scope_cap #(
    parameter AW          = 10,           // 深度 2^AW 点 (每点 = A/B 各 16 bit)
    parameter PRE         = 128,          // 预触发点数 (1 .. 2^AW-2)
    parameter HYST        = 64,           // 触发迟滞 (LSB)
    parameter AUTO_TO_CLK = 6_500_000     // 自动触发最短等待 (100 ms @ 65 MHz)
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire          smp_valid,      // 新样点 (与 smp_a/smp_b 同拍有效)
    input  wire [15:0]   smp_a,          // 补码
    input  wire [15:0]   smp_b,

    input  wire          arm,            // 单拍: 开始一次抓取
    input  wire [2:0]    trig_mode,
    input  wire          auto_en,
    input  wire [15:0]   trig_level,     // 补码, 与样点同单位
    input  wire [15:0]   decim,

    output reg           done,
    input  wire          clear,          // 单拍: 上传完成, 清 done
    output reg           forced,         // 本次为超时强制触发
    output reg  [2:0]    cap_mode,       // arm 时锁存的配置, 随数据上传
    output reg  [15:0]   cap_decim,

    input  wire [AW-1:0] rd_idx,
    output reg  [31:0]   rd_data         // {A, B}
);

    localparam [AW:0]   N     = 1 << AW;
    localparam [AW-1:0] PRE_W = PRE;

    localparam [1:0] S_IDLE = 2'd0,
                     S_PRE  = 2'd1,
                     S_WAIT = 2'd2,
                     S_POST = 2'd3;

    reg [1:0]    st;
    reg [AW-1:0] wr_ptr;
    reg [AW-1:0] start_ptr;
    reg [AW:0]   cnt;
    reg [15:0]   dec_cnt;
    reg [15:0]   level_r;
    reg          auto_r;
    reg          edge_armed;
    reg [23:0]   to_clk;
    reg [AW:0]   to_tick;
    wire         timeout = auto_r && (to_clk >= AUTO_TO_CLK) && to_tick[AW];

    wire tick = smp_valid && (dec_cnt == 16'd0) && (st != S_IDLE);

    // ---- 触发判定 (17 bit 有符号, 迟滞加减不溢出) ----
    wire               src_b   = (cap_mode == 3'd3) || (cap_mode == 3'd4);
    wire               rising  = (cap_mode == 3'd1) || (cap_mode == 3'd3);
    wire        [15:0] src     = src_b ? smp_b : smp_a;
    wire signed [16:0] s17     = {src[15], src};
    wire signed [16:0] lv17    = {level_r[15], level_r};
    wire signed [16:0] lo_th   = lv17 - HYST;
    wire signed [16:0] hi_th   = lv17 + HYST;
    wire               arm_cnd = rising ? (s17 <  lo_th) : (s17 >  hi_th);
    wire               hit_cnd = rising ? (s17 >= lv17)  : (s17 <= lv17);
    wire               trig_hit = (cap_mode == 3'd0) || (edge_armed && hit_cnd);

    // ---- 环形缓存 (推断为 BRAM, 简单双口) ----
    reg [31:0]   mem [0:(1<<AW)-1];
    reg [AW-1:0] rd_addr;

    always @(posedge clk) begin
        if (tick)
            mem[wr_ptr] <= {smp_a, smp_b};
        rd_addr <= start_ptr + rd_idx;
        rd_data <= mem[rd_addr];
    end

    // ---- 抓取状态机 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st         <= S_IDLE;
            wr_ptr     <= {AW{1'b0}};
            start_ptr  <= {AW{1'b0}};
            cnt        <= {(AW+1){1'b0}};
            dec_cnt    <= 16'd0;
            level_r    <= 16'd0;
            auto_r     <= 1'b1;
            edge_armed <= 1'b0;
            to_clk     <= 24'd0;
            to_tick    <= {(AW+1){1'b0}};
            done       <= 1'b0;
            forced     <= 1'b0;
            cap_mode   <= 3'd0;
            cap_decim  <= 16'd0;
        end else if (arm) begin
            st         <= S_PRE;
            cnt        <= {(AW+1){1'b0}};
            dec_cnt    <= 16'd0;
            level_r    <= trig_level;
            auto_r     <= auto_en;
            edge_armed <= 1'b0;
            to_clk     <= 24'd0;
            to_tick    <= {(AW+1){1'b0}};
            done       <= 1'b0;
            forced     <= 1'b0;
            cap_mode   <= (trig_mode > 3'd4) ? 3'd0 : trig_mode;
            cap_decim  <= decim;
        end else begin
            if (clear)
                done <= 1'b0;

            if (smp_valid && st != S_IDLE)
                dec_cnt <= (dec_cnt == 16'd0) ? cap_decim : dec_cnt - 16'd1;

            if (st == S_WAIT && !to_clk[23])
                to_clk <= to_clk + 24'd1;

            if (tick) begin
                wr_ptr <= wr_ptr + 1'b1;
                if (arm_cnd)
                    edge_armed <= 1'b1;

                case (st)
                    S_PRE: begin
                        cnt <= cnt + 1'b1;
                        if (cnt == PRE - 1)
                            st <= S_WAIT;
                    end
                    S_WAIT: begin
                        if (!to_tick[AW])
                            to_tick <= to_tick + 1'b1;
                        if (trig_hit || timeout) begin
                            start_ptr <= wr_ptr - PRE_W;
                            forced    <= !trig_hit;
                            cnt       <= {(AW+1){1'b0}};
                            st        <= S_POST;
                        end
                    end
                    S_POST: begin
                        cnt <= cnt + 1'b1;
                        if (cnt == N - PRE - 2) begin
                            st   <= S_IDLE;
                            done <= 1'b1;
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

endmodule
