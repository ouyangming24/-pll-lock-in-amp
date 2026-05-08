# =============================================================================
# update_clk_wiz_eth_for_idelay.tcl
#
# 给 clk_wiz_eth IP 增加 200 MHz 输出 (clk_out3),
# 用作 IDELAYCTRL 的参考时钟.
#
# 用法: 在 Vivado Tcl Console 跑
#   source g:/xiao/git_pll/tools/update_clk_wiz_eth_for_idelay.tcl
#
# 跑完后会自动重启 synth_1 + impl_1 + bitstream.
# =============================================================================

set ip_name "clk_wiz_eth"
set ip [get_ips $ip_name]

if {$ip eq ""} {
    puts "ERROR: 找不到 IP $ip_name. 请确认 Vivado 已经打开本工程."
    return
}

puts "==> 找到 IP: $ip"
puts "==> 当前配置:"
puts "    CLKOUT1: [get_property CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $ip] MHz, [get_property CONFIG.CLKOUT1_REQUESTED_PHASE $ip] deg"
puts "    CLKOUT2: [get_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $ip] MHz, [get_property CONFIG.CLKOUT2_REQUESTED_PHASE $ip] deg"

puts "==> 添加 CLKOUT3 = 200 MHz, 0 deg (给 IDELAYCTRL)..."

set_property -dict [list \
    CONFIG.NUM_OUT_CLKS                {3} \
    CONFIG.CLKOUT3_USED                {true} \
    CONFIG.CLK_OUT3_PORT               {clk_out3} \
    CONFIG.CLKOUT3_REQUESTED_OUT_FREQ  {200.000} \
    CONFIG.CLKOUT3_REQUESTED_PHASE     {0.000} \
    CONFIG.CLKOUT3_DRIVES              {BUFG} \
    CONFIG.CLKOUT3_REQUESTED_DUTY_CYCLE {50.000} \
] $ip

puts "==> 重新生成 IP 输出 (synthesis + simulation)..."
generate_target {synthesis simulation} [get_files ${ip_name}.xci]

# 重置 IP OOC run
set ip_run "${ip_name}_synth_1"
if {[llength [get_runs -quiet $ip_run]] > 0} {
    puts "==> 复位 IP OOC run: $ip_run ..."
    catch {reset_run $ip_run}
}

# 重置主综合 run (因为 IP 变了)
puts "==> 复位 synth_1 + impl_1 ..."
catch {reset_run impl_1}
catch {reset_run synth_1}

# 一键启动综合 + 实现 + 比特流
puts "==> 启动 impl_1 -to_step write_bitstream (后台运行, 会自动跑 synth_1)..."
launch_runs impl_1 -to_step write_bitstream -jobs 4

puts ""
puts "==============================================================="
puts "==> clk_wiz_eth 已升级为 3 输出:"
puts "    clk_out1 = 125 MHz (0 deg)"
puts "    clk_out2 = 125 MHz (90 deg)"
puts "    clk_out3 = 200 MHz  (IDELAYCTRL refclk)"
puts ""
puts "==> 综合 + 实现 + 比特流任务已经在后台运行."
puts "    在 Vivado 右下角的 'Design Runs' 窗口可以看到进度,"
puts "    全部跑完大约 30-90 分钟."
puts "    完成后:"
puts "    1. wait_on_run impl_1   (或 GUI 等绿色对勾)"
puts "    2. open_hw_manager"
puts "    3. program_device"
puts "==============================================================="
