# =============================================================================
#  一键更新所有 IP 核（迁移电脑/换 Vivado 版本后用）
#
#  用法 A（推荐：已在 GUI 打开工程时，Tcl Console）：
#        cd E:/company/Aunion/Lock_In_Amp/FPGA-2/git_pll
#        source update_ips.tcl
#
#  用法 B（Windows PowerShell / cmd，不要在 Vivado Tcl 里敲 vivado 命令）：
#        cd /d E:\company\Aunion\Lock_In_Amp\FPGA-2\git_pll
#        vivado -mode batch -source update_ips.tcl
# =============================================================================

# 始终以本脚本所在目录为工程根，避免 cwd 不对导致找不到 .xpr
set script_dir [file dirname [file normalize [info script]]]
cd $script_dir
puts "==> 工程目录: $script_dir"

set xpr_file [file join $script_dir project_1.xpr]
if {![file exists $xpr_file]} {
    puts "ERROR: 找不到工程文件: $xpr_file"
    return
}

# 如果没打开工程，自动打开；已打开则直接用当前工程
if {[catch {current_project} cur_proj]} {
    puts "==> 打开工程: $xpr_file"
    open_project $xpr_file
} else {
    puts "==> 使用已打开工程: $cur_proj"
}

# 纠正换机后残留的旧绝对路径（IP 缓存 / user files）
set proj_dir [get_property directory [current_project]]
set_property ip_output_repo    [file join $proj_dir project_1.cache ip] [current_project]
set_property ip_user_files_dir [file join $proj_dir project_1.ip_user_files] [current_project]
puts "==> IPOutputRepo    = [get_property ip_output_repo [current_project]]"
puts "==> IPUserFilesDir  = [get_property ip_user_files_dir [current_project]]"

set ips [get_ips]
if {[llength $ips] == 0} {
    puts "ERROR: 工程中没有 IP（get_ips 为空）"
    return
}
puts "==> 将处理 [llength $ips] 个 IP:"
foreach ip $ips { puts "    - $ip" }

# 1. 升级 IP（跨 Vivado 版本时必须）
puts "==> upgrade_ip ..."
upgrade_ip $ips

# 2. 重置并重新生成所有 IP 产物
puts "==> reset_target / generate_target ..."
reset_target all $ips
generate_target all $ips

# 3. 综合所有 IP（生成 .dcp，顶层综合必需）
puts "==> synth_ip ..."
synth_ip $ips

puts "OK: 所有 IP 已更新完成，可以 Run Synthesis 了"
