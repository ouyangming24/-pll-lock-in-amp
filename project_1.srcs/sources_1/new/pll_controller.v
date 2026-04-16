`timescale 1ns / 1ps
/*
 * 模块名称: pll_controller
 * 功能描述: 带有硬件自动扫频 (Sweep) 的数字锁相环 (PLL) 控制器
 *           失锁时自动扫描中心频率，捕捉到差频后启动 PI 拉入，
 *           并利用 X 通道(幅值)确认和维持锁定，彻底解决频率偏大无法锁定的问题。
 */
module pll_controller #(
    parameter integer KI_FRAC = 16,             // 积分项的小数拓展位数
    parameter IN_WIDTH = 28,                    // 输入误差信号位宽
    
    // 扫频(Sweep)相关参数
    // 65MHz 时钟下，1Hz 对应的频率控制字约 4330
    parameter signed [47:0] SWEEP_STEP = 48'd43303,      // 扫频步进：约 10 Hz
    parameter signed [47:0] SWEEP_LIMIT = 48'd433038425, // 扫频范围：±10 kHz (10000 * 4330)
    parameter SWEEP_INTERVAL = 16'd500,                  // 每 500 个 valid 节拍跳频一次
    
    // 捕捉与锁定确认阈值 (如果测试时一直在扫频不锁定，请调小这两个值！)
    parameter signed [IN_WIDTH-1:0] SWEEP_THRES = 28'd5000,   // Y通道捕捉阈值(差频幅度)
    parameter signed [IN_WIDTH-1:0] LOCK_X_THRES = 28'd8000,  // X通道锁定维持阈值(信号幅度)
    parameter WAIT_LOCK_TIME = 32'd2_000_000             // 锁定等待/防掉线容忍时间 (约2秒)
)(
    input  wire                 clk,        // 系统时钟
    input  wire                 rst_n,      // 异步复位，低电平有效
    input  wire                 pll_en,     // 锁相环使能开关
    input  wire signed [15:0]   pll_kp,     // 比例增益 (从UART来)
    input  wire signed [15:0]   pll_ki,     // 积分增益 (从UART来)
    input  wire signed [47:0]   center_freq,// 中心频率 (从UART来)
    input  wire signed [IN_WIDTH-1:0] phase_error_in, // 鉴相误差信号 (Y通道滤波输出)
    input  wire signed [IN_WIDTH-1:0] amp_in,         // 锁定指示信号 (X通道滤波幅值)
    input  wire                 valid_in,   // 误差信号有效标志 (作为 PI 节拍)
    output wire [47:0]          dds_freq_out,// 输出给 DDS 的频率控制字
    output wire                 is_locked   // 指示当前是否锁定的信号
);

    // 状态机
    localparam STATE_SWEEP = 1'b0;
    localparam STATE_LOCK  = 1'b1;
    reg state;

    // 积分与输出寄存器
    reg signed [63:0] pi_i_reg; 
    reg signed [47:0] pi_out;   

    // 扫频寄存器
    reg signed [47:0] sweep_offset;
    reg sweep_dir; // 0: 向上扫, 1: 向下扫
    reg [15:0] sweep_timer;
    
    // 锁定监控定时器
    reg [31:0] lock_timer;

    // 取绝对值用于阈值判断
    wire signed [IN_WIDTH-1:0] abs_y = phase_error_in[IN_WIDTH-1] ? -phase_error_in : phase_error_in;
    wire signed [IN_WIDTH-1:0] abs_x = amp_in[IN_WIDTH-1]         ? -amp_in         : amp_in;

    // 将输入误差符号扩展到 64 位，防止乘法溢出
    wire signed [63:0] phase_error_ext;
    assign phase_error_ext = { {(64-IN_WIDTH){phase_error_in[IN_WIDTH-1]}}, phase_error_in };

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_SWEEP;
            pi_i_reg <= 64'd0;
            pi_out   <= 48'd0;
            sweep_offset <= 48'd0;
            sweep_dir <= 1'b0;
            sweep_timer <= 16'd0;
            lock_timer <= 32'd0;
        end else if (pll_en) begin
            if (valid_in) begin
                if (state == STATE_SWEEP) begin
                    // ===== 扫频模式 =====
                    pi_i_reg <= 64'd0;
                    pi_out   <= 48'd0;
                    lock_timer <= 32'd0;
                    
                    if (abs_y > SWEEP_THRES) begin
                        // Y通道出现了明显的差频拍频，说明进入了低通滤波器的捕捉带宽内！
                        // 立即切换到锁定模式，让 PI 强行拉入
                        state <= STATE_LOCK;
                    end else begin
                        // 步进扫频
                        if (sweep_timer >= SWEEP_INTERVAL) begin
                            sweep_timer <= 16'd0;
                            if (sweep_dir == 1'b0) begin
                                if (sweep_offset < SWEEP_LIMIT)
                                    sweep_offset <= sweep_offset + SWEEP_STEP;
                                else
                                    sweep_dir <= 1'b1; // 碰顶，掉头向下扫
                            end else begin
                                if (sweep_offset > -SWEEP_LIMIT)
                                    sweep_offset <= sweep_offset - SWEEP_STEP;
                                else
                                    sweep_dir <= 1'b0; // 碰底，掉头向上扫
                            end
                        end else begin
                            sweep_timer <= sweep_timer + 1'b1;
                        end
                    end
                end else begin
                    // ===== 锁定/追踪模式 =====
                    // 1. 执行 PI 闭环控制
                    pi_i_reg <= pi_i_reg + (phase_error_ext * pll_ki);
                    pi_out   <= (phase_error_ext * pll_kp) + (pi_i_reg >>> KI_FRAC);
                    
                    // 2. 状态监控机制 (防假锁与信号掉线)
                    if (lock_timer < WAIT_LOCK_TIME) begin
                        lock_timer <= lock_timer + 1'b1;
                        // 如果 X 通道(幅值)升起来了，说明真正锁住了且信号存在
                        // 我们就一直重置定时器，维持锁定状态不死机
                        if (abs_x > LOCK_X_THRES) begin
                            lock_timer <= 32'd0; 
                        end
                    end else begin
                        // 等待时间耗尽(约2秒)，但 X 通道依然极低。
                        // 说明刚才的捕捉是假信号(如噪声导致超过阈值)，或者中途输入信号断开了
                        // 丢弃锁定，重新开始扫描！
                        state <= STATE_SWEEP;
                    end
                end
            end
        end else begin
            // 锁相环未使能时，复位状态
            state <= STATE_SWEEP;
            pi_i_reg <= 64'd0;
            pi_out   <= 48'd0;
        end
    end

    // 最终输出 = 基准中心频率 + 扫频偏移量(粗调) + PI反馈量(微调)
    assign dds_freq_out = center_freq + sweep_offset + pi_out;
    
    // 锁定指示灯 (1表示锁定，0表示正在扫描寻找信号)
    assign is_locked = (state == STATE_LOCK);

endmodule