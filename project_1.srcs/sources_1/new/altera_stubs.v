`timescale 1ns / 1ps
// =============================================================================
//  altera_stubs.v
//
//  作用:
//      verilog-ethernet 的 iddr.v / oddr.v 在 generate 块里同时引用了
//      Xilinx (IDDR/ODDR) 和 Altera (altddio_in / altddio_out) 原语.
//      本工程 TARGET="XILINX", Altera 分支不会被综合, 但 Vivado 在
//      Hierarchy 视图里仍会显示 altddio_in/altddio_out 红问号 (无害).
//
//      为了让 Hierarchy 视图干净, 这里提供两个空 stub. 综合时它们不会被例化
//      (因为 generate-if 在 elaboration 时就剔除了 ALTERA 分支), 仅满足
//      模块名解析.
//
//  注意:
//      - 这两个 stub 永远不会进入 netlist
//      - 端口列表只需要存在, 内部为空即可
// =============================================================================

(* keep_hierarchy = "no" *)
module altddio_in #(
    parameter integer WIDTH    = 1,
    parameter         INTENDED_DEVICE_FAMILY = "STRATIXII",
    parameter         INVERT_INPUT_CLOCKS    = "OFF",
    parameter         POWER_UP_HIGH          = "OFF",
    parameter         LPM_TYPE               = "altddio_in",
    parameter         LPM_HINT               = "UNUSED"
)(
    input                  inclock,
    input                  inclocken,
    input                  aset,
    input                  aclr,
    input                  sset,
    input                  sclr,
    input  [WIDTH-1:0]     datain,
    output [WIDTH-1:0]     dataout_h,
    output [WIDTH-1:0]     dataout_l
);
    // 永不被例化 (XILINX 综合时 generate 分支选不到这里)
endmodule


(* keep_hierarchy = "no" *)
module altddio_out #(
    parameter integer WIDTH    = 1,
    parameter         INTENDED_DEVICE_FAMILY = "STRATIXII",
    parameter         INVERT_OUTPUT          = "OFF",
    parameter         OE_REG                 = "UNUSED",
    parameter         EXTEND_OE_DISABLE      = "OFF",
    parameter         POWER_UP_HIGH          = "OFF",
    parameter         LPM_TYPE               = "altddio_out",
    parameter         LPM_HINT               = "UNUSED"
)(
    input                  outclock,
    input                  outclocken,
    input                  aset,
    input                  aclr,
    input                  sset,
    input                  sclr,
    input                  oe,
    input  [WIDTH-1:0]     datain_h,
    input  [WIDTH-1:0]     datain_l,
    output [WIDTH-1:0]     dataout,
    output                 oe_out
);
endmodule
