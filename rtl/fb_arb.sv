// fb_arb.sv — CONTRACTS §5/§7.3: fixed-priority fb memory arbiter,
// lfb(0) > fastfill(1) > pixel_pipe(2); one grant per cycle, read responses in
// program order.
//
// The RAM side is a VALID/READY handshake with a separate read-data-valid
// (ram_rd_valid), so the same arbiter drives either the on-chip 1-cycle fb_ram
// (sim / `make test`: ram_req_ready held high, ram_rd_valid one cycle after a read)
// OR the variable-latency PS-DDR4 path (KV260: fb_ddr_adapter). A tag FIFO of
// client-ids preserves response ordering across an arbitrary, variable number of
// outstanding reads. With the 1-cycle RAM and TAG_DEPTH>=2 this is BIT-IDENTICAL to
// the previous 1-deep-tag-pipe behaviour (verified: `make test` stays PIXEL-EXACT).
module fb_arb
  import voodoo_pkg::*;
#(
    parameter int unsigned TAG_DEPTH = 16   // max outstanding reads (power of 2)
) (
    input  logic              clk,
    input  logic              rst_n,

    // client 0: lfb_unit (highest priority)
    input  logic              c0_req_valid,
    output logic              c0_req_ready,
    input  logic              c0_req_we,
    input  logic [FB_AW-1:0]  c0_req_addr,
    input  logic [15:0]       c0_req_wdata,
    output logic              c0_rsp_valid,
    output logic [15:0]       c0_rsp_rdata,

    // client 1: fastfill
    input  logic              c1_req_valid,
    output logic              c1_req_ready,
    input  logic              c1_req_we,
    input  logic [FB_AW-1:0]  c1_req_addr,
    input  logic [15:0]       c1_req_wdata,
    output logic              c1_rsp_valid,
    output logic [15:0]       c1_rsp_rdata,

    // client 2: pixel_pipe (lowest priority)
    input  logic              c2_req_valid,
    output logic              c2_req_ready,
    input  logic              c2_req_we,
    input  logic [FB_AW-1:0]  c2_req_addr,
    input  logic [15:0]       c2_req_wdata,
    output logic              c2_rsp_valid,
    output logic [15:0]       c2_rsp_rdata,

    // fb memory side (handshake; variable read latency via ram_rd_valid)
    output logic              ram_req_valid,
    input  logic              ram_req_ready,
    output logic              ram_we,
    output logic [FB_AW-1:0]  ram_addr,
    output logic [15:0]       ram_wdata,
    input  logic              ram_rd_valid,
    input  logic [15:0]       ram_rdata
);
  localparam int unsigned AW = $clog2(TAG_DEPTH);

  // ---- fixed-priority select (c0 > c1 > c2) ----
  logic             grant_valid, sel_we;
  logic [1:0]       sel_cli;
  logic [FB_AW-1:0] sel_addr;
  logic [15:0]      sel_wdata;
  always_comb begin
    grant_valid = c0_req_valid | c1_req_valid | c2_req_valid;
    if (c0_req_valid) begin
      sel_cli = 2'd0; sel_we = c0_req_we; sel_addr = c0_req_addr; sel_wdata = c0_req_wdata;
    end else if (c1_req_valid) begin
      sel_cli = 2'd1; sel_we = c1_req_we; sel_addr = c1_req_addr; sel_wdata = c1_req_wdata;
    end else begin
      sel_cli = 2'd2; sel_we = c2_req_we; sel_addr = c2_req_addr; sel_wdata = c2_req_wdata;
    end
  end

  // ---- tag FIFO: client-id per outstanding read, popped in order on rd_valid ----
  logic [1:0]   tag_mem [0:TAG_DEPTH-1];
  logic [AW-1:0] tag_wp, tag_rp;
  logic [AW:0]   tag_cnt;                      // 0..TAG_DEPTH; top bit set == full
  wire           tag_full = tag_cnt[AW];

  wire sel_is_read = grant_valid & ~sel_we;
  // present the request unless it is a read with no room to track its response
  assign ram_req_valid = grant_valid & ~(sel_is_read & tag_full);
  assign ram_we        = sel_we;
  assign ram_addr      = sel_addr;
  assign ram_wdata     = sel_wdata;

  wire fire = ram_req_valid & ram_req_ready;   // request accepted this cycle
  assign c0_req_ready = (sel_cli == 2'd0) & fire;
  assign c1_req_ready = (sel_cli == 2'd1) & fire;
  assign c2_req_ready = (sel_cli == 2'd2) & fire;

  wire push = fire & sel_is_read;              // remember a read's client
  wire pop  = ram_rd_valid;                    // its response returned, in order

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tag_wp <= '0; tag_rp <= '0; tag_cnt <= '0;
    end else begin
      if (push) begin tag_mem[tag_wp] <= sel_cli; tag_wp <= tag_wp + AW'(1); end
      if (pop)  tag_rp <= tag_rp + AW'(1);
      tag_cnt <= tag_cnt + {{AW{1'b0}}, push} - {{AW{1'b0}}, pop};
    end
  end

  wire [1:0] tag_head = tag_mem[tag_rp];
  always_comb begin
    c0_rsp_valid = ram_rd_valid & (tag_head == 2'd0);
    c1_rsp_valid = ram_rd_valid & (tag_head == 2'd1);
    c2_rsp_valid = ram_rd_valid & (tag_head == 2'd2);
    c0_rsp_rdata = ram_rdata;
    c1_rsp_rdata = ram_rdata;
    c2_rsp_rdata = ram_rdata;
  end

endmodule
