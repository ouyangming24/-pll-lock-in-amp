# =============================================================================
# ad7606c_bd_update.tcl
#   AD9248 x2 → AD7606C-16 后, 更新 design_1 (lock_in_amp 为 module reference):
#     1) 把 ad7606c_drv.v 加入 sources_1
#     2) 刷新 lock_in_amp_0 模块引用 (端口已改)
#     3) 删除旧的 adc_*_0 外部端口, 把新的 ad_* 引脚引出为外部端口 (名字带 _0)
#     4) 校验、保存、重新生成 design_1_wrapper
#
#   用法: 打开 project_1.xpr 后, 在 Vivado Tcl Console 执行
#     source <git_pll>/tools/ad7606c_bd_update.tcl
# =============================================================================

set repo [file normalize [file join [file dirname [info script]] ..]]
set drv  [file join $repo project_1.srcs sources_1 new ad7606c_drv.v]

if {[llength [get_files -quiet $drv]] == 0} {
    add_files -norecurse -fileset sources_1 $drv
}
update_compile_order -fileset sources_1

set bd_file [get_files design_1.bd]
open_bd_design $bd_file

update_module_reference [get_ips design_1_lock_in_amp_0_0]

foreach p {adc_data_0 adc_data_2_0 adc_otr_0 adc_otr_2_0 adc_pdn_0 adc_pdn_2_0
           adc_oeb_b_0 adc_oeb_b_2_0 adc_clk_0 adc_clk_2_0} {
    set obj [get_bd_ports -quiet $p]
    if {[llength $obj]} {
        delete_bd_objs $obj
    }
}

foreach pin {ad_db ad_convst ad_wr_n ad_rd_n ad_cs_n ad_reset ad_os ad_busy ad_frstdata} {
    set bp [get_bd_pins lock_in_amp_0/$pin]
    if {[llength [get_bd_nets -quiet -of_objects $bp]] == 0} {
        make_bd_pins_external $bp
    }
}

validate_bd_design
save_bd_design

# ad_db 与 ft_d 一样是 inout, BD 必须保持 Global 综合 (见 fix_bd_ooc_ft245.tcl)
set_property synth_checkpoint_mode None $bd_file
generate_target all $bd_file
make_wrapper -files $bd_file -top -force

puts "AD7606C: design_1 updated. External ports:"
foreach p [lsort [get_bd_ports ad_*]] { puts "  $p" }
