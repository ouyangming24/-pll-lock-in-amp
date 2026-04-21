# =============================================================================
#  一键更新所有 IP 核（迁移电脑/换 Vivado 版本后用）
#
#  用法：
#    Vivado 打开工程后，Tcl Console 里输入：
#        source update_ips.tcl
#
#    或命令行一键全自动：
#        vivado -mode batch -source update_ips.tcl project_1.xpr
# =============================================================================

# 如果没打开工程，自动打开
if {[catch {current_project}]} {
    open_project project_1.xpr
}

# 1. 升级 IP（跨 Vivado 版本时必须）
upgrade_ip [get_ips]

# 2. 重置并重新生成所有 IP 产物
reset_target  all [get_ips]
generate_target all [get_ips]

# 3. 综合所有 IP（生成 .dcp，顶层综合必需）
synth_ip [get_ips]

puts "✓ 所有 IP 已更新完成，可以 Run Synthesis 了"
