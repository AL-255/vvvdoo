# synth_pl_top.tcl — OOC synthesis of the complete KV260 PL IP (voodoo_pl_top =
# axi_voodoo_slave + board voodoo_top + fb_ddr_adapter) on xck26, for the real
# board fabric utilization. Texture -> URAM (TEX_AW=17), framebuffer -> external
# AXI (DDR, an OOC boundary). Synth-only; place/route happens in the full BD.
#   vivado -mode batch -source fpga/kv260/synth_pl_top.tcl
set part xck26-sfvc784-2LV-c
set root [file normalize [file dirname [info script]]/../..]
set rpt  $root/fpga/reports

read_verilog -sv $root/rtl/voodoo_pkg.sv
foreach f [glob $root/rtl/*.sv] {
  if {[file tail $f] ne "voodoo_pkg.sv"} { read_verilog -sv $f }
}
# board RTL (NOT fb_ram_stub.sv -- it redefines fb_ram; NOT axi_mem_sim.sv -- sim only)
read_verilog -sv $root/fpga/kv260/rtl/axi_voodoo_slave.sv
read_verilog -sv $root/fpga/kv260/rtl/fb_ddr_adapter.sv
read_verilog -sv $root/fpga/kv260/rtl/voodoo_pl_top.sv

synth_design -top voodoo_pl_top -part $part -mode out_of_context \
             -verilog_define VOODOO_INT -verilog_define VOODOO_FB_DDR \
             -verilog_define VOODOO_TEX_AW=17

report_utilization -file $rpt/kv260_pl_util.rpt
set lut  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set ff   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == REGISTER}]]
set uram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]
set bram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]]
set dsp  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == DSP}]]
puts "PLFIT lut=$lut/117120 ff=$ff/234240 uram=$uram/64 bram=$bram/144 dsp=$dsp/1248"
puts "PLFIT report: $rpt/kv260_pl_util.rpt"
