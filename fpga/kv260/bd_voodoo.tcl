# bd_voodoo.tcl — Vivado block design + build for vvvdoo on the KV260 (xck26).
#   vivado -mode batch -source fpga/kv260/bd_voodoo.tcl
#
# Assembles: Zynq US+ PS -> SmartConnect -> axi_voodoo_slave -> voodoo_top, with
# fb_ddr_adapter mastering PS DDR4 over S_AXI_HP0. Single PL clock (50 MHz bring-up),
# synchronous reset. See fpga/kv260/README.md for the full architecture + rationale.
#
# PREREQUISITES (M7 RTL — see README §3/§6; this script is the build recipe and will
# not place-and-route until they land):
#   1. rtl/fb_arb.sv rewritten for variable AXI read latency (tagged, in-order resp).
#   2. fpga/kv260/rtl/fb_ddr_adapter.sv datapath implemented (currently a skeleton).
#   3. voodoo_top's internal fb_ram instance exposed as an fb master port wired to
#      fb_ddr_adapter (a board variant of voodoo_top), texture kept on-chip (URAM).
# Until then, use this script's synth-only path (set FIT_ONLY=1) for the §6 step-1
# fit/inference GATE (texture <=64 URAM, true-dual-port byte-write URAM, no cascade).

set PART  xck26-sfvc784-2LV-c
set BOARD xilinx.com:k26c:part0:1.4
set TEXAW 17                                  ;# reduced texture: 128K x16 = 2.1Mb = 32 URAM
set ROOT  [file normalize [file dirname [info script]]/../..]
set FIT_ONLY [expr {[info exists ::env(FIT_ONLY)] ? $::env(FIT_ONLY) : 0}]

create_project voodoo_kv260 $ROOT/fpga/kv260/build_kv260 -part $PART -force
set_property board_part $BOARD [current_project]

# core RTL (voodoo_pkg first) + the KV260 wrappers
read_verilog -sv $ROOT/rtl/voodoo_pkg.sv
read_verilog -sv [glob $ROOT/rtl/*.sv]
read_verilog -sv [glob $ROOT/fpga/kv260/rtl/*.sv]
# integer backend + reduced on-chip texture; force URAM for the RAMs
set_property verilog_define [list VOODOO_INT TEX_AW=$TEXAW] [current_fileset]

# -------- synth-only fit/inference GATE (README §6 step 1) --------
if {$FIT_ONLY} {
  synth_design -top voodoo_top -part $PART -mode out_of_context \
               -verilog_define VOODOO_INT -verilog_define TEX_AW=$TEXAW
  report_utilization -file $ROOT/fpga/reports/kv260_fit_util.rpt
  puts "FIT_ONLY done -> fpga/reports/kv260_fit_util.rpt (check URAM <= 64, no BRAM cascade)"
  return
}

# -------- full block design --------
create_bd_design voodoo_bd

# 1) Zynq UltraScale+ PS (board preset): PL_CLK0=100MHz, PL_RESETN0,
#    M_AXI_HPM0_LPD (host MMIO), S_AXI_HP0_FPD (framebuffer -> DDR).
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} [get_bd_cells ps]
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} ] [get_bd_cells ps]

# 2) clk_wiz: 100MHz -> 50MHz bring-up clock; 3) proc_sys_reset (sync-deassert)
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz clkw
set_property -dict [list CONFIG.PRIM_IN_FREQ {100} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000}] [get_bd_cells clkw]
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rstgen

# 4) SmartConnect: 1 master (HPM0_LPD) -> 2 slaves (BAR, STAT)
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] [get_bd_cells sc]

# 5) the RTL cells (module references; AXI ifaces inferred from port naming)
create_bd_cell -type module -reference axi_voodoo_slave slave
create_bd_cell -type module -reference voodoo_top       core
create_bd_cell -type module -reference fb_ddr_adapter   fbddr

# --- clocking/reset: ONE clock everywhere (no host-port CDC); timed sync reset ---
# wire clkw.clk_out1 -> all ACLKs + core.clk; rstgen.peripheral_aresetn -> all *RESETN + core.rst_n
# wire ps PL_CLK0 -> clkw.clk_in1, ps maxihpm0/saxihp0 aclk <- clkw.clk_out1
# wire slave.host_* <-> core host_*; core fb master <-> fbddr; fbddr.M_AXI -> ps.S_AXI_HP0
# (explicit connect_bd_net/connect_bd_intf_net lines elided here — fill per README §4;
#  validate_bd_design must report NO axi_clock_converter inserted.)

# 6) address map: BAR @0x8000_0000 / 16M, STAT @0x8001_0000 / 64K; fbddr sees PS DDR.
assign_bd_address
# set_property offset 0x80000000 [get_bd_addr_segs {ps/.../slave_S_AXI_BAR/*}]
# set_property range  16M         ...
# set_property offset 0x80010000 [get_bd_addr_segs {ps/.../slave_S_AXI_STAT/*}]
# set_property range  64K         ...

validate_bd_design
make_wrapper -files [get_files voodoo_bd.bd] -top
add_files [glob $ROOT/fpga/kv260/build_kv260/*/hdl/voodoo_bd_wrapper.v]
add_files -fileset constrs_1 $ROOT/fpga/kv260/voodoo_kv260.xdc
set_property top voodoo_bd_wrapper [current_fileset]

launch_runs synth_1 -jobs 8 ; wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8 ; wait_on_run impl_1
puts "bitstream: build_kv260/voodoo_kv260.runs/impl_1/voodoo_bd_wrapper.bit"
