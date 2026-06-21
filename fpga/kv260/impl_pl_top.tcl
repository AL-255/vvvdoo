# impl_pl_top.tcl — full OOC implementation (synth -> opt -> place -> phys_opt ->
# route) of the KV260 PL IP (voodoo_pl_top) on xck26, at the 50 MHz bring-up clock.
# Writes the routed checkpoint, utilization + timing summary, and a placement dump
# (every placed leaf cell's site LOC + hierarchy path) for the device-view plot.
#   vivado -mode batch -source fpga/kv260/impl_pl_top.tcl [-tclargs PERIOD_NS TAG]
# PERIOD_NS: target clock period (default 20 = 50 MHz; 10 = 100 MHz).
# TAG: filename suffix so a tight run does not clobber the baseline reports.
set part   xck26-sfvc784-2LV-c
set period [expr {[llength $argv] > 0 ? [lindex $argv 0] : 20.000}]
set tag    [expr {[llength $argv] > 1 ? [lindex $argv 1] : ""}]
set tight  [expr {$period <= 12.0}]      ;# push hard for >=80 MHz targets
set root   [file normalize [file dirname [info script]]/../..]
set rpt    $root/fpga/reports

read_verilog -sv $root/rtl/voodoo_pkg.sv
foreach f [glob $root/rtl/*.sv] {
  if {[file tail $f] ne "voodoo_pkg.sv"} { read_verilog -sv $f }
}
read_verilog -sv $root/fpga/kv260/rtl/axi_voodoo_slave.sv
read_verilog -sv $root/fpga/kv260/rtl/fb_ddr_adapter.sv
read_verilog -sv $root/fpga/kv260/rtl/voodoo_pl_top.sv

# tight runs add register retiming (netlist-only; RTL/`make test` unaffected)
set synflags [list -top voodoo_pl_top -part $part -mode out_of_context \
              -verilog_define VOODOO_INT -verilog_define VOODOO_FB_DDR \
              -verilog_define VOODOO_TEX_AW=17]
if {$tight} { lappend synflags -retiming }
synth_design {*}$synflags
create_clock -name clk -period $period [get_ports clk]

opt_design
if {$tight} {
  # strategy (argv[3]) selects place/route directives for a timing-closure sweep
  set strat [expr {[llength $argv] > 2 ? [lindex $argv 2] : "explore"}]
  switch -- $strat {
    timing { set pdir ExtraTimingOpt;        set rdir NoTimingRelaxation }
    spread { set pdir AltSpreadLogic_high;   set rdir AggressiveExplore }
    aggr   { set pdir Explore;               set rdir AggressiveExplore }
    default { set strat explore; set pdir Explore; set rdir Explore }
  }
  puts "STRATEGY=$strat place=$pdir route=$rdir"
  place_design -directive $pdir
  phys_opt_design -directive AggressiveExplore
  route_design -directive $rdir
  phys_opt_design                              ;# post-route timing cleanup
} else {
  place_design
  phys_opt_design
  route_design
}

report_utilization                       -file $rpt/kv260_impl${tag}_util.rpt
report_timing_summary -delay_type max -max_paths 10 -file $rpt/kv260_impl${tag}_timing.rpt
report_timing -max_paths 6 -nworst 6 -sort_by group -file $rpt/kv260_impl${tag}_worst.rpt
write_checkpoint -force $rpt/kv260_routed${tag}.dcp

# ---- placement dump for the device view: "SITE<TAB>cell_hier_path" ----
set cells [get_cells -hier -filter {PRIMITIVE_LEVEL == LEAF}]
set fh [open $rpt/kv260_placement${tag}.txt w]
foreach c $cells {
  set loc [get_property LOC $c]
  if {$loc ne ""} { puts $fh "$loc\t$c" }
}
close $fh

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "IMPLDONE period=${period}ns WNS=${wns}ns -> Fmax [format %.1f [expr {1000.0/($period-$wns)}]] MHz"
puts "IMPLDONE reports -> $rpt/kv260_impl${tag}_*.rpt ; placement -> kv260_placement${tag}.txt"
