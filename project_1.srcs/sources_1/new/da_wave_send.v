module da_wave_send(
	input  wire 			 CLK_DAC904	,
	input  wire 			 SYS_RST	,
	input  wire	[13:0]	     DATA_BUF   ,
	output wire				 PD			,
	output wire				 DAC_CLK	,
	output wire	[13:0]       DAC_DATA
);

// DAC904的输出电压转换公式：(16383 - DAC_DATA) * （6V/16383），此公式默认不使用输出放大缩小，短路帽接12
assign PD = 1'b0;
assign DAC_CLK  = CLK_DAC904;
assign DAC_DATA = DATA_BUF; // 交流输出
//assign DAC_DATA = 14'd10000; // 直流测试，0.66V左右

endmodule
