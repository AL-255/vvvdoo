# ceiling_timing.tcl — estimate the Fmax ceiling of the datapath if the two
# unpipelined combinational dividers (raster edge/slope divide; TMU perspective
# divide) were pipelined out of the critical path. We reuse the post-route
# checkpoint and declare the divider *output* registers as timing cut points,
# then re-report the worst remaining setup path. This does NOT re-implement —
# it just tells us what the next bottleneck is.

set rpt [file normalize [file dirname [info script]]/../reports]
open_checkpoint $rpt/post_route.dcp

# Divider result registers (combinational divide feeds these flops).
set cut [get_cells -quiet -hier -regexp {.*/(coord_[st]_q_reg|s_q_reg|t_q_reg|ay_q_reg|by_q_reg|cy_q_reg|iy[0-9]_q_reg|span_[a-z0-9_]*q_reg|x_start_q_reg|x_end_q_reg).*}]
puts "cut-point registers: [llength $cut]"
set_false_path -to $cut

# Also cut the internal divide DSP/quotient endpoints the router named.
set cut2 [get_cells -quiet -hier -regexp {.*vd_edge_x.*}]
if {[llength $cut2]} { set_false_path -to $cut2 }

report_timing_summary -delay_type max -max_paths 10 -file $rpt/ceiling_timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "CEILING_WNS $wns"
puts [format "CEILING_FMAX_at_4ns %.1f MHz" [expr {1000.0/(4.0 - $wns)}]]
