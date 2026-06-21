# impl_pl_top.tcl — full OOC implementation (synth -> opt -> place -> phys_opt ->
# route) of the KV260 PL IP (voodoo_pl_top) on xck26, at the 50 MHz bring-up clock.
# Writes the routed checkpoint, utilization + timing summary, and a placement dump
# (every placed leaf cell's site LOC + hierarchy path) for the device-view plot.
#   vivado -mode batch -source fpga/kv260/impl_pl_top.tcl
set part   xck26-sfvc784-2LV-c
set period 20.000          ;# 50 MHz bring-up clock
set root   [file normalize [file dirname [info script]]/../..]
set rpt    $root/fpga/reports

read_verilog -sv $root/rtl/voodoo_pkg.sv
foreach f [glob $root/rtl/*.sv] {
  if {[file tail $f] ne "voodoo_pkg.sv"} { read_verilog -sv $f }
}
read_verilog -sv $root/fpga/kv260/rtl/axi_voodoo_slave.sv
read_verilog -sv $root/fpga/kv260/rtl/fb_ddr_adapter.sv
read_verilog -sv $root/fpga/kv260/rtl/voodoo_pl_top.sv

synth_design -top voodoo_pl_top -part $part -mode out_of_context \
             -verilog_define VOODOO_INT -verilog_define VOODOO_FB_DDR \
             -verilog_define VOODOO_TEX_AW=17
create_clock -name clk -period $period [get_ports clk]

opt_design
place_design
phys_opt_design
route_design

report_utilization                       -file $rpt/kv260_impl_util.rpt
report_timing_summary -delay_type max -max_paths 10 -file $rpt/kv260_impl_timing.rpt
write_checkpoint -force $rpt/kv260_routed.dcp

# ---- placement dump for the device view: "SITE<TAB>cell_hier_path" ----
set cells [get_cells -hier -filter {PRIMITIVE_LEVEL == LEAF}]
set fh [open $rpt/kv260_placement.txt w]
foreach c $cells {
  set loc [get_property LOC $c]
  if {$loc ne ""} { puts $fh "$loc\t$c" }
}
close $fh

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "IMPLDONE period=${period}ns WNS=${wns}ns -> Fmax [format %.1f [expr {1000.0/($period-$wns)}]] MHz"
puts "IMPLDONE placement -> $rpt/kv260_placement.txt"
