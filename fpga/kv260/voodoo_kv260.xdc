# voodoo_kv260.xdc — KV260 block-design constraints. Fresh file (NOT a copy of
# fpga/syn/voodoo_ooc.xdc, which references a nonexistent top-level `clk` port and
# false-paths the reset). See fpga/kv260/README.md §4.
#
# Clock: clk_wiz emits the create_generated_clock for clk_out1 (50 MHz bring-up)
# automatically — do NOT add a manual create_clock on a top-level port. Raise the
# clk_wiz output frequency only after impl closes timing with margin on xck26-2LV
# (the 85 MHz figure was a datapath-only OOC run on a faster/bigger part).
#
# Reset is SYNCHRONOUS active-low (rtl/host_if.sv:79 and every submodule are
#   always_ff @(posedge clk) if (!rst_n) ...).  There are NO async-reset blocks.
# Therefore rst_n must be TIMED — intentionally NO `set_false_path -from ... rst_n`.
# If reset fanout becomes a timing problem, fix it with a pipelined reset tree /
# max_fanout / a reset BUFG — never a false_path on a synchronous reset.
#
# The only genuine asynchronous crossing is inside fb_ddr_adapter (voodoo clk <->
# HP-UI clk); that is owned by its async FIFO IP, which carries its own constraints.
# No top-level set_false_path / set_max_delay is required here for bring-up.

# (Pin/IO constraints come from the board preset + PS; this PL design has no direct
#  top-level board pins — all I/O is via the PS AXI ports.)
