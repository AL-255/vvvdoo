# voodoo_ooc.xdc — out-of-context timing constraints for voodoo_top on ZU15EG.
#
# Single synchronous clock domain (clk). The clock is (re)defined in the tcl so
# the target period can be swept; this file constrains the reset and the OOC
# I/O budget. Fmax is derived from the post-route WNS as 1000/(period - WNS).

# Async, active-low reset — not a timed launch path.
set_false_path -from [get_ports rst_n]

# Modest OOC I/O budget so the boundary is neither free nor the critical path.
# (clk is excluded; it carries the create_clock above.)
set clk_port [get_ports clk]
set in_ports  [filter [all_inputs]  "NAME != clk"]
set out_ports [all_outputs]
set_input_delay  -clock clk 1.000 $in_ports
set_output_delay -clock clk 1.000 $out_ports
