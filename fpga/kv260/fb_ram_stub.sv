// fb_ram_stub.sv — fit-gate ONLY. Registered stub for the framebuffer RAM so the
// fit/inference check (fpga/kv260/fit_check.tcl) measures the REAL tex_ram URAM
// inference + datapath fit without synthesizing the 4 MB FB (which goes to PS DDR4
// on the board — see README §3). Folds all addr/we/data into a registered read so
// nothing on the FB path is trimmed. NOT for hardware (use fb_ddr_adapter there).
`default_nettype none
module fb_ram
  import voodoo_pkg::*;
(
    input  wire logic              clk,
    input  wire logic              we,
    input  wire logic [FB_AW-1:0]  addr,
    input  wire logic [15:0]       wdata,
    output      logic [15:0]       rdata
);
  always_ff @(posedge clk)
    rdata <= (we ? wdata : 16'h0) ^ addr[15:0] ^ {11'h0, addr[FB_AW-1:16]};
endmodule
`default_nettype wire
