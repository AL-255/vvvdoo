// tex_ram.sv — CONTRACTS §5/§7.3: 1M x 16 RAM, per-byte write enables (write-only
// until the M3 TMU sampler). Contents uninitialized; TB zero-fills via 'mem'.
module tex_ram
  import voodoo_pkg::*;
(
    input  logic               clk,
    input  logic [1:0]         we,     // per-byte enables: [0]=bits 7:0, [1]=bits 15:8
    input  logic [TEX_AW-1:0]  addr,   // 16-bit word address
    input  logic [15:0]        wdata,
    // M3 TMU read port (1-cycle registered read; temporally disjoint from
    // the write port, so no arbitration is required — CONTRACTS §11b)
    input  logic [TEX_AW-1:0]  addr_r,
    output logic [15:0]        rdata_r
);

  localparam int unsigned DEPTH = 1 << TEX_AW;

  // ram_style="ultra": map to UltraRAM on FPGA targets (KV260: TEX_AW=17 -> 32 URAM,
  // true-dual-port byte-write). Ignored by Verilator, so sim is unaffected.
  (* ram_style = "ultra" *)
  logic [15:0] mem [0:DEPTH-1] /* verilator public_flat_rw */;

  always_ff @(posedge clk) begin
    if (we[0])
      mem[addr][7:0] <= wdata[7:0];
    if (we[1])
      mem[addr][15:8] <= wdata[15:8];
    rdata_r <= mem[addr_r];
  end

endmodule
