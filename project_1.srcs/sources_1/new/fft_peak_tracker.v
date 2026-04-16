`timescale 1ns / 1ps

/*
 * 模块名称: fft_peak_tracker
 * 功能描述: 自动跟踪信号中心频率的模块
 *           1. 内部例化 xfft_0 (1024点)
 *           2. 解析复数结果并流水线计算幅值平方
 *           3. 自动寻找第一半频区(屏蔽直流)的最大峰值
 *           4. 将峰值对应的频率索引转换成 48位中心频率，直接喂给 pll_controller
 */
module fft_peak_tracker #(
    parameter FFT_POINTS = 65536,
    // DDS_FTW_MULT (频率控制字乘数)
    // 计算公式: (Fs / FFT_POINTS) * (2^48 / Fclk)
    // 65MHz / 65536 点: 2^48 / 65536 = 2^32 = 48'h0001_0000_0000
    parameter [47:0] BIN_TO_FTW = 48'h0001_0000_0000 
)(
    input  wire        clk,
    input  wire        rst_n,

    // ==========================================
    // 时域数据输入 (接 ADC 或 下变频前的数据)
    // ==========================================
    input  wire [31:0] s_axis_data_tdata,   // [31:16]可以全填0，[15:0]填 ADC 输入实数
    input  wire        s_axis_data_tvalid,
    input  wire        s_axis_data_tlast,   // 必须每 1024 个点拉高一次
    output wire        s_axis_data_tready,

    // ==========================================
    // 输出给 pll_controller 的目标参数
    // ==========================================
    output reg signed [47:0] center_freq,   // 喂给 pll_controller 的 center_freq
    output reg               freq_update_valid // 脉冲，指示 center_freq 刚好更新
);

    // ==========================================
    // 1. FFT IP 配置与例化
    // ==========================================
    reg  [7:0] config_tdata;
    reg        config_tvalid;
    wire       config_tready;
    reg        config_done;

    // 复位后，只需给 FFT 发送一次配置 (FWD_INV = 1，做正向FFT)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            config_tdata  <= 8'b0000_0001;
            config_tvalid <= 1'b0;
            config_done   <= 1'b0;
        end else begin
            if (!config_done) begin
                config_tvalid <= 1'b1;
                // 握手成功，结束配置
                if (config_tvalid && config_tready) begin
                    config_done   <= 1'b1;
                    config_tvalid <= 1'b0;
                end
            end else begin
                config_tvalid <= 1'b0;
            end
        end
    end

    wire [31:0] m_axis_data_tdata;
    wire [23:0] m_axis_data_tuser;
    wire        m_axis_data_tvalid;
    wire        m_axis_data_tlast;
    
    // 例化生成的 xfft_0
    xfft_0 u_xfft (
        .aclk                        (clk),
        .aresetn                     (rst_n),
        .s_axis_config_tdata         (config_tdata),
        .s_axis_config_tvalid        (config_tvalid),
        .s_axis_config_tready        (config_tready),
        
        .s_axis_data_tdata           (s_axis_data_tdata),
        .s_axis_data_tvalid          (s_axis_data_tvalid),
        .s_axis_data_tready          (s_axis_data_tready),
        .s_axis_data_tlast           (s_axis_data_tlast),
        
        .m_axis_data_tdata           (m_axis_data_tdata),
        .m_axis_data_tuser           (m_axis_data_tuser),
        .m_axis_data_tvalid          (m_axis_data_tvalid),
        .m_axis_data_tready          (1'b1), // 下游总是准备好
        .m_axis_data_tlast           (m_axis_data_tlast),
        
        .m_axis_status_tdata         (),     // 状态信息暂不需要
        .m_axis_status_tvalid        (),
        .m_axis_status_tready        (1'b1),
        
        .event_frame_started         (),
        .event_tlast_unexpected      (),
        .event_tlast_missing         (),
        .event_status_channel_halt   (),
        .event_data_in_channel_halt  (),
        .event_data_out_channel_halt ()
    );

    // ==========================================
    // 2. 数据解析与流水线平方计算
    // ==========================================
    // 提取实部和虚部 (参考截图中 CHAN_0_XN_IM [29:16] 和 CHAN_0_XN_RE [13:0])
    wire signed [13:0] re_in = m_axis_data_tdata[13:0];
    wire signed [13:0] im_in = m_axis_data_tdata[29:16];
    // 提取当前频率索引 (65536点占用 16位)
    wire        [15:0] index_in = m_axis_data_tuser[15:0]; 
    
    // 符号扩展至16位，防止乘法器溢出
    wire signed [15:0] re_ext = {{2{re_in[13]}}, re_in};
    wire signed [15:0] im_ext = {{2{im_in[13]}}, im_in};

    // [第1级流水线]: 乘法计算平方
    reg signed [31:0] re_sq;
    reg signed [31:0] im_sq;
    reg        [15:0] index_d1;
    reg               valid_d1;
    reg               last_d1;

    always @(posedge clk) begin
        if (m_axis_data_tvalid) begin
            re_sq <= re_ext * re_ext;
            im_sq <= im_ext * im_ext;
        end
        index_d1 <= index_in;
        valid_d1 <= m_axis_data_tvalid;
        last_d1  <= m_axis_data_tvalid & m_axis_data_tlast;
    end

    // [第2级流水线]: 加法求平方和 (幅值平方)
    reg [32:0] mag_sq;
    reg [15:0] index_d2;
    reg        valid_d2;
    reg        last_d2;

    always @(posedge clk) begin
        if (valid_d1) begin
            mag_sq <= $unsigned(re_sq) + $unsigned(im_sq);
        end
        index_d2 <= index_d1;
        valid_d2 <= valid_d1;
        last_d2  <= last_d1;
    end

    // ==========================================
    // 3. 峰值搜索与中心频率换算
    // ==========================================
    reg [32:0] max_mag_sq;
    reg [15:0] best_index;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max_mag_sq <= 0;
            best_index <= 0;
            center_freq <= 0;
            freq_update_valid <= 0;
        end else begin
            freq_update_valid <= 1'b0; // 默认输出一个时钟周期的脉冲
            
            if (valid_d2) begin
                // 只看有效正频率 (1 到 N/2 - 1)
                // 【极其重要】屏蔽直流分量 (index=0)，否则很容易把低频本底噪声当成最大频率
                if (index_d2 > 16'd0 && index_d2 < (FFT_POINTS/2)) begin
                    if (mag_sq > max_mag_sq) begin
                        max_mag_sq <= mag_sq;
                        best_index <= index_d2;
                    end
                end
                
                // 一帧 FFT 数据输出完毕，结算结果
                if (last_d2) begin
                    // center_freq = 峰值索引 * 每根谱线对应的频率字
                    center_freq <= best_index * BIN_TO_FTW;
                    freq_update_valid <= 1'b1;
                    
                    // 清零峰值，准备找下一帧的最大值
                    max_mag_sq <= 0;
                end
            end
        end
    end

endmodule
