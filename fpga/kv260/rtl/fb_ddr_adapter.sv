// fb_ddr_adapter.sv — SKELETON (M7, NOT YET FUNCTIONAL).
//
// Intended to replace the on-chip fb_ram instance in voodoo_top: bridge the
// framebuffer RAM-side port to an AXI4 master into PS DDR4 (KV260 S_AXI_HP0_FPD),
// so the 4 MB framebuffer lives in DRAM (it cannot fit on-chip — see
// fpga/kv260/README.md §3). This file defines the INTERFACE only; the datapath
// (async R/W FIFOs for the voodoo-clk <-> HP-UI-clk crossing, AXI burst issue,
// 2-byte WSTRB sub-word writes, tagged read responses) is M7 work.
//
// IMPORTANT — this adapter is useless without the paired fb_arb.sv rewrite:
//   fb_ram presents a FIXED 1-cycle read latency with no backpressure; DDR is
//   variable-latency. fb_arb.sv (rtl/) must be rewritten to a multi-entry tag
//   FIFO that (a) makes cN_req_ready = "cmd FIFO not full", (b) drives cN_rsp_valid
//   from the ACTUAL AXI read-response return, (c) keeps responses in order (single
//   ARID). The pixel_pipe / lfb_unit / fastfill clients already advance on rsp_valid,
//   so their FSMs are unchanged. Gate the whole change on `make test` staying
//   byte-identical to gold using a latency-injecting fb stub BEFORE wiring real DDR.
//
// FB byte address of word W = FB_BASE_BYTES + W*2 (off-by-2x corrupts the image;
// scan_front_base is a 16-bit WORD offset).
`default_nettype none

module fb_ddr_adapter
  import voodoo_pkg::*;
#(
    parameter int          AXI_DATA_W      = 64,           // S_AXI_HP data width
    parameter logic [31:0] FB_BASE_BYTES   = 32'h7000_0000 // DDR fb region base
) (
    // ---- voodoo clock domain (fb_ram replacement port; see fb_arb rewrite) ----
    input  wire logic              clk,
    input  wire logic              rst_n,
    input  wire logic              we,         // 16-bit subword write
    input  wire logic [FB_AW-1:0]  addr,       // word address
    input  wire logic [15:0]       wdata,
    output wire logic [15:0]       rdata,       // valid 1 tag later (see rd_valid)
    output wire logic              rd_valid,    // tagged read-data valid (NEW vs fb_ram)

    // ---- AXI4 master to PS DDR (S_AXI_HP0_FPD), HP UI clock domain ----
    input  wire logic              axi_aclk,
    input  wire logic              axi_aresetn,
    output wire logic [48:0]       m_axi_awaddr,
    output wire logic [7:0]        m_axi_awlen,
    output wire logic              m_axi_awvalid,
    input  wire logic              m_axi_awready,
    output wire logic [AXI_DATA_W-1:0]   m_axi_wdata,
    output wire logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output wire logic              m_axi_wlast,
    output wire logic              m_axi_wvalid,
    input  wire logic              m_axi_wready,
    input  wire logic [1:0]        m_axi_bresp,
    input  wire logic              m_axi_bvalid,
    output wire logic              m_axi_bready,
    output wire logic [48:0]       m_axi_araddr,
    output wire logic [7:0]        m_axi_arlen,
    output wire logic              m_axi_arvalid,
    input  wire logic              m_axi_arready,
    input  wire logic [AXI_DATA_W-1:0]   m_axi_rdata,
    input  wire logic [1:0]        m_axi_rresp,
    input  wire logic              m_axi_rlast,
    input  wire logic              m_axi_rvalid,
    output wire logic              m_axi_rready
);
  // ====================== SKELETON BODY (M7 TODO) ======================
  // Drive the AXI master idle and return zero so the module elaborates and
  // lints. Replace with: write-combining buffer + AXI write burst issue
  // (2-byte WSTRB), read-command async FIFO (clk->axi_aclk), read-data async
  // FIFO (axi_aclk->clk) returning {tag,data}, and rd_valid from the data FIFO.
  assign m_axi_awaddr  = '0;
  assign m_axi_awlen   = '0;
  assign m_axi_awvalid = 1'b0;
  assign m_axi_wdata   = '0;
  assign m_axi_wstrb   = '0;
  assign m_axi_wlast   = 1'b0;
  assign m_axi_wvalid  = 1'b0;
  assign m_axi_bready  = 1'b1;
  assign m_axi_araddr  = '0;
  assign m_axi_arlen   = '0;
  assign m_axi_arvalid = 1'b0;
  assign m_axi_rready  = 1'b1;
  assign rdata         = 16'h0;
  assign rd_valid      = 1'b0;

  // tie-off until the datapath is implemented
  wire _unused = &{1'b0, clk, rst_n, we, addr, wdata, axi_aclk, axi_aresetn,
                   m_axi_awready, m_axi_wready, m_axi_bresp, m_axi_bvalid,
                   m_axi_arready, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid,
                   FB_BASE_BYTES};
endmodule

`default_nettype wire
