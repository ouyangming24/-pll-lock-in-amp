`timescale 1ns / 1ps

/*
 * 模块名称: iir_lpf_ema
 * 功能描述: 高精度一阶IIR低通滤波器（指数移动平均）
 *           用于锁相放大器提取极微弱直流信号，替代庞大的低频RC滤波器。
 * 核心算法: y[n] = y[n-1] + (x[n] - y[n-1]) * (2^-k)
 */
module iir_lpf_ema #(
    parameter IN_WIDTH   = 24,  // 输入数据位宽 (例如 CIC滤波器输出的24位有符号数)
    parameter FRAC_WIDTH = 24   // ★核心：内部小数扩展位宽 (必须 >= 最大的 shift_k，防止截断死区)
)(
    input  wire                     clk,        // 系统时钟
    input  wire                     rst_n,      // 异步复位，低电平有效
    input  wire                     en,         // 数据有效使能 (来自CIC的降采样节拍)
    input  wire [4:0]               shift_k,    // 滤波器带宽参数 k (等效公式中的 α = 2^-k)
    input  wire signed [IN_WIDTH-1:0] din,      // 乘法器/CIC送来的输入数据 (带噪声的直流)
    output reg  signed [IN_WIDTH-1:0] dout,     // 滤波后的纯净直流数据
    output reg                      valid_out   // 输出数据有效标志
);

    // 总累加器位宽 = 整数部分(原数据) + 小数部分
    localparam ACC_WIDTH = IN_WIDTH + FRAC_WIDTH;

    // ★ shift_k 安全上限：移位量最大为 ACC_WIDTH - 1
    // 超过此值会导致 diff_shifted 全部变为符号位扩展（信号归零，滤波器死锁）
    // 例如 IN_WIDTH=28, FRAC_WIDTH=24 时，ACC_WIDTH=52，shift_k 上限为 51
    // 由于 shift_k 是 5bit（最大31），此配置下天然安全，无需运行时钳位
    // 若未来修改参数导致 ACC_WIDTH < 32，则需在此处加钳位逻辑
    localparam SHIFT_MAX = ACC_WIDTH - 1;

    // 内部高精度累加器（低位为小数位，高位为整数位）
    reg  signed [ACC_WIDTH-1:0] y_acc;
    
    // 信号线定义，严格声明为有符号数以保证算术右移(>>>)带符号位扩展
    wire signed [ACC_WIDTH-1:0] din_scaled;
    wire signed [ACC_WIDTH-1:0] diff;
    wire signed [ACC_WIDTH-1:0] diff_shifted;

    // ★ shift_k 运行时钳位：确保移位量不超过 ACC_WIDTH-1
    // 使用 wire 做钳位，不额外引入寄存器延迟
    wire [4:0] shift_k_safe = (shift_k > SHIFT_MAX[4:0]) ? SHIFT_MAX[4:0] : shift_k;

    // 1. 将输入数据对齐到累加器的高位 (相当于乘以 2^FRAC_WIDTH)
    assign din_scaled = {din, {FRAC_WIDTH{1'b0}}};

    // 2. 计算当前输入与当前累加值的差值：(x[n] - y[n-1])
    assign diff = din_scaled - y_acc;

    // 3. ★ 使用钳位后的 shift_k_safe 进行算术右移，彻底防止位移越界
    assign diff_shifted = diff >>> shift_k_safe;

    // 4. 时序逻辑：更新累加器与输出
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y_acc     <= {ACC_WIDTH{1'b0}};
            dout      <= {IN_WIDTH{1'b0}};
            valid_out <= 1'b0;
        end else begin
            valid_out <= 1'b0;
            
            if (en) begin
                y_acc     <= y_acc + diff_shifted;
                // 将高精度累加器剔除小数位，还原回真实数据位宽后输出
                // 加入四舍五入(Rounding)逻辑以降低舍入噪声和极限环振荡
                // 传统截断是直接丢弃低位，相当于向下取整。加上低位最高位的值可以实现四舍五入。
                dout      <= (y_acc + diff_shifted + {1'b0, 1'b1, {(FRAC_WIDTH-1){1'b0}}}) >>> FRAC_WIDTH; 
                valid_out <= 1'b1;
            end
        end
    end

endmodule