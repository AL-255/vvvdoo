# fit_check.tcl — KV260 fit/inference GATE (README §6 step 1).
#   vivado -mode batch -source fpga/kv260/fit_check.tcl
# Synth-only OOC of voodoo_top on xck26 with the integer backend, reduced texture
# (VOODOO_TEX_AW=17), REAL tex_ram (ram_style="ultra"), and the FB stubbed (-> DDR
# on board). Confirms: datapath fits, and texture infers URAM (<=64, no BRAM cascade).
set part xck26-sfvc784-2LV-c
set root [file normalize [file dirname [info script]]/../..]
set rpt  $root/fpga/reports

read_verilog -sv $root/rtl/voodoo_pkg.sv
foreach f [glob $root/rtl/*.sv] {
  set b [file tail $f]
  if {$b ne "voodoo_pkg.sv" && $b ne "fb_ram.sv"} { read_verilog -sv $f }
}
read_verilog -sv $root/fpga/kv260/fb_ram_stub.sv

synth_design -top voodoo_top -part $part -mode out_of_context \
             -verilog_define VOODOO_INT -verilog_define VOODOO_TEX_AW=17

report_utilization -file $rpt/kv260_fit_util.rpt
set uram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]
set bram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]]
set dsp  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == DSP}]]
puts "FITGATE uram=$uram (of 64)  bram=$bram (of 144)  dsp=$dsp (of 1248)"
puts "FITGATE report: $rpt/kv260_fit_util.rpt"
