// fb_ram.sv — CONTRACTS §5/§6: 2M x 16 single-port sync RAM, 1-cycle read latency.
// Contents uninitialized; TB zero-fills via the public 'mem' array at t=0.
module fb_ram
  import voodoo_pkg::*;
(
    input  logic              clk,
    input  logic              we,
    input  logic [FB_AW-1:0]  addr,
    input  logic [15:0]       wdata,
    output logic [15:0]       rdata
);

  localparam int unsigned DEPTH = 1 << FB_AW;

  logic [15:0] mem [0:DEPTH-1] /* verilator public_flat_rw */;

  always_ff @(posedge clk) begin
    if (we)
      mem[addr] <= wdata;
    rdata <= mem[addr];
  end

endmodule
