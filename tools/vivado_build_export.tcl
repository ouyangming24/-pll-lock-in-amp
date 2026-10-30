# =============================================================================
# vivado_build_export.tcl
#
# 批量: 打开 project_1 → 综合/实现/出 bit → 导出含 bitstream 的 XSA
#
# 用法 (在 git_pll 根目录):
#   vivado -mode batch -source tools/vivado_build_export.tcl
# 或由 rebuild_sd_boot.ps1 调用.
#
# 可选 Tcl 变量 (用 -tclargs 或调用前 set):
#   jobs          并行核数, 默认 8
#   xsa_out       输出 XSA 路径, 默认 <proj>/design_1_wrapper.xsa
#   skip_impl     1 = 已有 bit 只导出 XSA
# =============================================================================

set proj_dir [file normalize [file dirname [file dirname [info script]]]]
set xpr      [file join $proj_dir project_1.xpr]

if {![info exists jobs]}      { set jobs 8 }
if {![info exists xsa_out]}   { set xsa_out [file join $proj_dir design_1_wrapper.xsa] }
if {![info exists skip_impl]} { set skip_impl 0 }

puts "==== vivado_build_export ===="
puts "project : $xpr"
puts "xsa_out : $xsa_out"
puts "jobs    : $jobs"
puts "skip_impl: $skip_impl"

if {![file exists $xpr]} {
    error "找不到工程: $xpr"
}

open_project $xpr

# 只改内部逻辑时无需 Refresh; 端口变更请先在 GUI 里 Refresh Module
update_compile_order -fileset sources_1

set bit_file [file join $proj_dir project_1.runs impl_1 design_1_wrapper.bit]

if {!$skip_impl} {
    # 源有变更时 reset synth, 再串到 write_bitstream
    set do_reset 0
    if {[catch {get_property NEEDS_REFRESH [get_runs synth_1]} nr] == 0} {
        if {$nr} { set do_reset 1 }
    }
    set prog [get_property PROGRESS [get_runs synth_1]]
    if {$prog ne "100%"} { set do_reset 1 }
    if {$do_reset} {
        puts "reset_run synth_1 (PROGRESS=$prog)"
        reset_run synth_1
    }

    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_on_run impl_1

    set impl_status [get_property STATUS [get_runs impl_1]]
    puts "impl status: $impl_status"
    if {![file exists $bit_file]} {
        error "未生成 bitstream: $bit_file (STATUS=$impl_status)"
    }
} else {
    if {![file exists $bit_file]} {
        error "skip_impl=1 但找不到 bit: $bit_file"
    }
    puts "跳过综合实现, 使用已有 bit"
}

puts "导出 XSA (include bitstream) ..."
write_hw_platform -fixed -include_bit -force -file $xsa_out
puts "OK: $xsa_out"
puts "OK: $bit_file"

close_project
exit 0
