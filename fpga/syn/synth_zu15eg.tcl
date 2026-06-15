# synth_zu15eg.tcl — out-of-context synth + place + route of the vvvdoo Voodoo
# datapath on a Xilinx Zynq UltraScale+ ZU15EG, integer backend (VOODOO_INT).
#
#   vivado -mode batch -source fpga/syn/synth_zu15eg.tcl [-tclargs <period_ns>]
#
# The framebuffer / texture stores are external DRAM (see ram_blackbox.sv), so
# this reports the fabric datapath area and post-route Fmax of the integer
# rasterizer/TMU/pixel pipeline. Reports land in fpga/reports/.

set part   xczu15eg-ffvb1156-2-i
set top    voodoo_top
set period [expr {[llength $argv] > 0 ? [lindex $argv 0] : 4.000}]

set root   [file normalize [file dirname [info script]]/../..]
set rtl    $root/rtl
set rpt    $root/fpga/reports
file mkdir $rpt

puts "=== vvvdoo OOC build: part=$part top=$top target_period=${period}ns (VOODOO_INT) ==="

# ---- read sources (integer backend; black-box the external DRAM RAMs) --------
read_verilog -sv $rtl/voodoo_pkg.sv
foreach f {reg_decode float_conv host_if voodoo_regfile cmd_dispatch \
           fb_arb fastfill lfb_unit tex_dl srt_div raster tmu pixel_pipe voodoo_top} {
  read_verilog -sv $rtl/$f.sv
}
read_verilog -sv $root/fpga/syn/ram_blackbox.sv

# ---- synth (out-of-context: no I/O buffers) ----------------------------------
synth_design -top $top -part $part -mode out_of_context \
             -verilog_define VOODOO_INT \
             -flatten_hierarchy rebuilt

# Constraints are applied post-synthesis (the clock must exist before the XDC's
# input/output-delay statements reference it).
create_clock -name clk -period $period [get_ports clk]
read_xdc -unmanaged $root/fpga/syn/voodoo_ooc.xdc

report_utilization     -file $rpt/post_synth_util.rpt
report_timing_summary  -file $rpt/post_synth_timing.rpt
write_checkpoint -force $rpt/post_synth.dcp

# ---- implement (opt/place/route) for true timing -----------------------------
opt_design
place_design
phys_opt_design
route_design

# ---- final reports -----------------------------------------------------------
report_utilization                       -file $rpt/post_route_util.rpt
report_utilization -hierarchical         -file $rpt/post_route_util_hier.rpt
report_timing_summary -delay_type max -max_paths 20 -file $rpt/post_route_timing.rpt
report_timing -max_paths 10 -nworst 10 -sort_by group -file $rpt/post_route_worst_paths.rpt
write_checkpoint -force $rpt/post_route.dcp

# ---- machine-readable summary ------------------------------------------------
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set fmax [expr {1000.0 / ($period - $wns)}]
set fh [open $rpt/SUMMARY.txt w]
puts $fh "part            $part"
puts $fh "target_period   ${period} ns"
puts $fh "WNS             ${wns} ns"
puts $fh [format "Fmax            %.1f MHz" $fmax]
puts $fh "luts            [llength [get_cells -hier -filter {PRIMITIVE_GROUP==LUT}]]"
puts $fh "regs            [llength [get_cells -hier -filter {PRIMITIVE_GROUP==REGISTER}]]"
puts $fh "dsps            [llength [get_cells -hier -filter {PRIMITIVE_GROUP==BLOCKRAM || REF_NAME==DSP48E2 || REF_NAME==DSP58}]]"
close $fh
puts "=== DONE. Summary: ==="
puts [exec cat $rpt/SUMMARY.txt]
