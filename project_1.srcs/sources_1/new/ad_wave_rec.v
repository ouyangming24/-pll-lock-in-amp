module ad_wave_rec(
    input   wire          CLK_65M  ,
    input   wire          RST_N    ,
    input   wire  [13:0]  ADC_IN   ,
    input   wire          OTR      ,
    output  wire          PDN      ,
    output  wire          OEB_B    ,
    output  wire          ADC_CLK  ,
    output  wire  [13:0]  ADC_OUTA ,
    output  wire  [13:0]  ADC_OUTB
);
//ADC采集到数据和电压转换公式为：(ADC_DATA - 8192) * (20/16384)
//采集到的数据通过 Signal_Tap II 查看

//AD9248的最大采样率为65Mhz，最低采样率为1Mhz

wire           DATA_CLK ;
reg     [13:0] ADC_BUFA ;  //ADCA数据缓存器
reg     [13:0] ADC_BUFB ;  //ADCB数据缓存器

//ADCB数据读取
always@(negedge ADC_CLK or negedge RST_N)
begin
    if(!RST_N)begin
        ADC_BUFB  <= 14'd0;
    end
    else begin
        ADC_BUFB  <= ADC_IN ; // 有符号转无符号处理,并反向
    end
end

//ADCA数据读取
always@(posedge ADC_CLK or negedge RST_N)
begin
    if(!RST_N)begin
        ADC_BUFA  <= 14'd0;
    end
    else begin
        ADC_BUFA  <= ADC_IN; // 有符号转无符号处理,并反向
    end
end

assign OEB_B    = 1'b0;
assign PDN      = 1'b0;
assign ADC_CLK  = CLK_65M;
assign ADC_OUTA = ADC_BUFA;
assign ADC_OUTB = ADC_BUFB;


endmodule
