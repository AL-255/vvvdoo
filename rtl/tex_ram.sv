// tex_ram.sv — CONTRACTS §5/§7.3: 1M x 16 RAM, per-byte write enables (write-only
// until the M3 TMU sampler). Contents uninitialized; TB zero-fills via 'mem'.
module tex_ram
  import voodoo_pkg::*;
(
    input  logic               clk,
    input  logic [1:0]         we,     // per-byte enables: [0]=bits 7:0, [1]=bits 15:8
    input  logic [TEX_AW-1:0]  addr,   // 16-bit word address
    input  logic [15:0]        wdata
);

  localparam int unsigned DEPTH = 1 << TEX_AW;

  logic [15:0] mem [0:DEPTH-1] /* verilator public_flat_rw */;

  always_ff @(posedge clk) begin
    if (we[0])
      mem[addr][7:0] <= wdata[7:0];
    if (we[1])
      mem[addr][15:8] <= wdata[15:8];
  end

endmodule
