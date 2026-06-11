// fb_arb.sv — CONTRACTS §5/§7.3: fixed-priority fb_ram arbiter, lfb(0) > fastfill(1)
// > pixel_pipe(2); one grant per cycle, read responses in order (1-deep tag pipe).
module fb_arb
  import voodoo_pkg::*;
(
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

    // fb_ram side
    output logic              ram_we,
    output logic [FB_AW-1:0]  ram_addr,
    output logic [15:0]       ram_wdata,
    input  logic [15:0]       ram_rdata
);

  logic       grant_valid;
  logic       grant_we;
  logic [1:0] grant_cli;

  always_comb begin
    c0_req_ready = 1'b1;
    c1_req_ready = ~c0_req_valid;
    c2_req_ready = ~c0_req_valid & ~c1_req_valid;

    grant_valid = c0_req_valid | c1_req_valid | c2_req_valid;
    if (c0_req_valid) begin
      grant_cli = 2'd0; grant_we = c0_req_we;
      ram_addr  = c0_req_addr; ram_wdata = c0_req_wdata;
    end else if (c1_req_valid) begin
      grant_cli = 2'd1; grant_we = c1_req_we;
      ram_addr  = c1_req_addr; ram_wdata = c1_req_wdata;
    end else begin
      grant_cli = 2'd2; grant_we = c2_req_we;
      ram_addr  = c2_req_addr; ram_wdata = c2_req_wdata;
    end
    ram_we = grant_valid & grant_we;
  end

  // read response tag pipeline: matches fb_ram's 1-cycle read latency
  logic       rd_pend_q;
  logic [1:0] rd_cli_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_pend_q <= 1'b0;
      rd_cli_q  <= 2'd0;
    end else begin
      rd_pend_q <= grant_valid & ~grant_we;
      rd_cli_q  <= grant_cli;
    end
  end

  always_comb begin
    c0_rsp_valid = rd_pend_q & (rd_cli_q == 2'd0);
    c1_rsp_valid = rd_pend_q & (rd_cli_q == 2'd1);
    c2_rsp_valid = rd_pend_q & (rd_cli_q == 2'd2);
    c0_rsp_rdata = ram_rdata;
    c1_rsp_rdata = ram_rdata;
    c2_rsp_rdata = ram_rdata;
  end

endmodule
