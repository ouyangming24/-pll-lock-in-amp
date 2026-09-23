# =============================================================================
#  fix_bd_ooc_ft245.tcl
#  在 Vivado Tcl Console、工程已打开时执行:
#      source E:/company/Aunion/Lock_In_Amp/FPGA-2/git_pll/fix_bd_ooc_ft245.tcl
#
#  关键是 BD 的 synth_checkpoint_mode = None（Global 综合）。
#  module_ref 的 generate_synth_checkpoint 是只读属性，不要去改。
# =============================================================================

set bd_file [get_files -quiet design_1.bd]
if {$bd_file eq ""} {
    error "未找到 design_1.bd, 请先打开 project_1.xpr"
}

set_property synth_checkpoint_mode None $bd_file
puts "OK  design_1.bd synth_checkpoint_mode = [get_property synth_checkpoint_mode $bd_file]"

# lock_in_amp.xci 的 generate_synth_checkpoint 对 module_ref 只读，跳过即可。
# 只要 BD 是 None/Global，OOC 双 IOBUF 就不会再出现。

puts "下一步:"
puts "  1) 打开 design_1.bd → Generate Output Products → 选 Global → Generate"
puts "  2) Reset Runs 后重新综合/实现，生成 design_1_wrapper.bit"
puts "  3) JTAG 先烧 wrapper.bit，XCOM 发 KP:1，应回 Command Success!"
