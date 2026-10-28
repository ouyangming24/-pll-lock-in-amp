# =============================================================================
# uart_only_bd_update.tcl
#   去掉以太网, 命令 + 数据全走板载 CH340 串口 (PL 端 L17/M17) 后, 更新 design_1
#   (lock_in_amp 为 module reference):
#     1) 启用 uart_link / uart_rec / uart_send; 停用以太网源文件与 clk_wiz_eth
#     2) 刷新 lock_in_amp_0 模块引用 (端口已改)
#     3) 删除 eth_*_0 外部端口, 把 uart_txd / uart_rxd 引出为外部端口 (名字带 _0)
#     4) 校验、保存、重新生成 design_1_wrapper
#
#   用法: 打开 project_1.xpr 后, 在 Vivado Tcl Console 执行
#     source E:/company/Aunion/Lock_In_Amp/FPGA-2/git_pll/tools/uart_only_bd_update.tcl
#   然后 Generate Bitstream.
#   恢复以太网: 还原 lock_in_amp.v / pin_solidify.xdc 后执行 eth_only_bd_update.tcl
# =============================================================================

set repo [file normalize [file join [file dirname [info script]] ..]]
set new  [file join $repo project_1.srcs sources_1 new]
set ve   [file join $repo third_party verilog-ethernet]

foreach f [list [file join $new uart_link.v] [file join $new uart_rec.v] [file join $new uart_send.v]] {
    if {![file exists $f]} { error "缺少源文件: $f" }
    set obj [get_files -quiet $f]
    if {[llength $obj] == 0} {
        add_files -norecurse -fileset sources_1 $f
        set obj [get_files $f]
    }
    set_property is_enabled true $obj
}

set eth_srcs [list \
    [file join $new eth_udp_link.v] \
    [file join $new udp_stream_tx.v] \
    [file join $new eth_phy_init.v]]
foreach f {eth_mac_1g_rgmii_fifo eth_mac_1g_rgmii rgmii_phy_if ssio_ddr_in iddr oddr eth_mac_1g
           axis_gmii_rx axis_gmii_tx lfsr mac_ctrl_rx mac_ctrl_tx mac_pause_ctrl_rx mac_pause_ctrl_tx
           eth_axis_rx eth_axis_tx udp_complete udp udp_ip_rx udp_ip_tx udp_checksum_gen
           ip_complete ip ip_eth_rx ip_eth_tx ip_arb_mux arp arp_cache arp_eth_rx arp_eth_tx eth_arb_mux} {
    lappend eth_srcs [file join $ve rtl $f.v]
}
foreach f {axis_async_fifo axis_async_fifo_adapter axis_adapter axis_fifo arbiter priority_encoder} {
    lappend eth_srcs [file join $ve lib axis rtl $f.v]
}
foreach f $eth_srcs {
    set obj [get_files -quiet $f]
    if {[llength $obj]} { set_property is_enabled false $obj }
}
set eth_xci [get_files -quiet clk_wiz_eth.xci]
if {[llength $eth_xci]} { set_property is_enabled false $eth_xci }

update_compile_order -fileset sources_1

set bd_file [get_files design_1.bd]
open_bd_design $bd_file

update_module_reference [get_ips design_1_lock_in_amp_0_0]

foreach p {eth_rxc_0 eth_rxctl_0 eth_rxd_0 eth_txc_0 eth_txctl_0 eth_txd_0 eth_nrst_0 eth_mdc_0 eth_mdio_0
           ft_d_0 ft_rxf_n_0 ft_rd_n_0 ft_txe_n_0 ft_wr_0} {
    set obj [get_bd_ports -quiet $p]
    if {[llength $obj]} {
        delete_bd_objs $obj
    }
}

foreach pin {uart_rxd uart_txd pl_led1 pl_led2} {
    set bp [get_bd_pins lock_in_amp_0/$pin]
    if {[llength [get_bd_nets -quiet -of_objects $bp]] == 0} {
        make_bd_pins_external $bp
    }
}

validate_bd_design
save_bd_design

# ad_db 是 inout, BD 必须保持 Global 综合
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file
make_wrapper -files $bd_file -top -force

puts "UART-ONLY: design_1 updated. External ports:"
foreach p [lsort [get_bd_ports {uart_* pl_led* eth_*}]] { puts "  $p" }
