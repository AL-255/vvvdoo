// axi_mem_sim.sv — SIM-ONLY behavioral AXI4 slave used to verify fb_ddr_adapter
// end-to-end in the Verilator trace-diff (no Vivado/DDR model needed). It speaks
// the same narrow 2-byte protocol fb_ddr_adapter emits and stores into an external
// 16-bit word memory port (wired to the real fb_ram, so the TB's
// voodoo_top.u_fb_ram.mem readback path is preserved). Single outstanding,
// matching the adapter. NOT synthesized. Build via `make test-fbddr`.
`default_nettype none

module axi_mem_sim #(
    parameter int AXI_AW = 49
) (
    input  wire logic              clk,
    input  wire logic              rst_n,
    // AXI4 slave (from fb_ddr_adapter)
    input  wire logic [AXI_AW-1:0] awaddr,
    input  wire logic [7:0]        awlen,
    input  wire logic [2:0]        awsize,
    input  wire logic [1:0]        awburst,
    input  wire logic              awvalid,
    output wire logic              awready,
    input  wire logic [31:0]       wdata,
    input  wire logic [3:0]        wstrb,
    input  wire logic              wlast,
    input  wire logic              wvalid,
    output wire logic              wready,
    output wire logic [1:0]        bresp,
    output wire logic              bvalid,
    input  wire logic              bready,
    input  wire logic [AXI_AW-1:0] araddr,
    input  wire logic [7:0]        arlen,
    input  wire logic [2:0]        arsize,
    input  wire logic [1:0]        arburst,
    input  wire logic              arvalid,
    output wire logic              arready,
    output wire logic [31:0]       rdata,
    output wire logic [1:0]        rresp,
    output wire logic              rlast,
    output wire logic              rvalid,
    input  wire logic              rready,
    // 16-bit word memory port (to fb_ram)
    output wire logic              mem_we,
    output wire logic [FB_AW-1:0]  mem_addr,
    output wire logic [15:0]       mem_wdata,
    input  wire logic [15:0]       mem_rdata
);
  import voodoo_pkg::*;
  typedef enum logic [2:0] { M_IDLE, M_W, M_B, M_RD, M_RD2 } mstate_e;
  mstate_e            st;
  logic [AXI_AW-1:0]  waddr_q, raddr_q;

  assign awready = (st == M_IDLE);
  assign arready = (st == M_IDLE) & ~awvalid;          // writes win, single outstanding
  assign wready  = (st == M_W);
  assign bvalid  = (st == M_B);
  assign bresp   = 2'b00;
  assign rvalid  = (st == M_RD2);
  assign rlast   = 1'b1;
  assign rresp   = 2'b00;
  // mem_addr holds raddr across M_RD/M_RD2, so mem_rdata is stable in M_RD2; place
  // the 16-bit word on the lane selected by byte-addr bit 1 (matches the adapter).
  assign rdata   = raddr_q[1] ? {mem_rdata, 16'h0} : {16'h0, mem_rdata};

  // word memory port: write on the W beat; read address presented in M_RD
  wire [FB_AW-1:0] waddr_word = waddr_q[FB_AW:1];      // byte>>1
  wire [FB_AW-1:0] raddr_word = raddr_q[FB_AW:1];
  assign mem_we    = (st == M_W) & wvalid;
  assign mem_addr  = (st == M_W) ? waddr_word : raddr_word;
  assign mem_wdata = wstrb[2] ? wdata[31:16] : wdata[15:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= M_IDLE; waddr_q <= '0; raddr_q <= '0;
    end else begin
      unique case (st)
        M_IDLE: begin
          if (awvalid)      begin waddr_q <= awaddr; st <= M_W; end
          else if (arvalid) begin raddr_q <= araddr; st <= M_RD; end
        end
        M_W:   if (wvalid)  st <= M_B;                 // fb_ram write takes effect
        M_B:   if (bready)  st <= M_IDLE;
        M_RD:               st <= M_RD2;               // addr presented; data next cycle
        M_RD2: if (rready)  st <= M_IDLE;
        default: st <= M_IDLE;
      endcase
    end
  end

  // tie-off: single fixed-size narrow beats (len/size/burst/wlast unused); only
  // address bits [FB_AW:1] (word) and [1] (lane) matter, the rest are unused.
  wire _unused = &{1'b0, awlen, awsize, awburst, arlen, arsize, arburst, wlast, wstrb[3:0],
                   waddr_q[AXI_AW-1:FB_AW+1], waddr_q[0],
                   raddr_q[AXI_AW-1:FB_AW+1], raddr_q[0]};
endmodule

`default_nettype wire
