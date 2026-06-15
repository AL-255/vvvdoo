// ram_blackbox.sv — OOC implementation stubs for the two large RAMs.
//
// On the real Voodoo Graphics SST-1 the framebuffer (2M x 16 = 4 MB) and the
// texture store (1M x 16 = 2 MB) are EXTERNAL EDO DRAM, not on-chip. On a ZU15EG
// board they map to the on-board DDR4 behind a memory controller. For a
// datapath area/timing report we therefore do NOT instantiate the 48 Mib of
// array in fabric; instead we model each memory as a single registered
// read-data boundary (one flop, 1-cycle latency — the same boundary a BRAM,
// URAM, or DDR4 read-return register would present).
//
// Crucially every address / write-enable / write-data input is folded into the
// registered output so none of the address-generation or write datapath in the
// surrounding logic is trimmed away. This keeps the reported area/timing of the
// rasterizer/TMU/pixel-pipeline honest while keeping the build placeable.
// (Used by synth_zu15eg.tcl in place of rtl/fb_ram.sv and rtl/tex_ram.sv.)

module fb_ram
  import voodoo_pkg::*;
(
    input  logic              clk,
    input  logic              we,
    input  logic [FB_AW-1:0]  addr,
    input  logic [15:0]       wdata,
    output logic [15:0]       rdata
);
  // Fold the full address (all FB_AW bits) + write inputs into a registered
  // value so the boundary presents one real read flop and trims nothing.
  always_ff @(posedge clk)
    rdata <= (we ? wdata : 16'h0) ^ addr[15:0] ^ {11'h0, addr[FB_AW-1:16]};
endmodule

module tex_ram
  import voodoo_pkg::*;
(
    input  logic               clk,
    input  logic [1:0]         we,
    input  logic [TEX_AW-1:0]  addr,
    input  logic [15:0]        wdata,
    input  logic [TEX_AW-1:0]  addr_r,
    output logic [15:0]        rdata_r
);
  // Read port (addr_r) is what the TMU sampler times against; fold the write
  // port in too so nothing on the upload path is optimized out.
  always_ff @(posedge clk)
    rdata_r <= addr_r[15:0] ^ {12'h0, addr_r[TEX_AW-1:16]}
             ^ ((|we) ? (wdata ^ addr[15:0]) : 16'h0);
endmodule
