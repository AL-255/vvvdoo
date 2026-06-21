// voodoo_pl_top.sv — the complete PL user IP for the KV260 block design: the AXI4
// slave wrapper + the board-configured voodoo_top (framebuffer in PS DDR4). The BD
// instantiates THIS as one cell and wires:
//   S_AXI_BAR  (AXI4)      <- PS M_AXI_HPM0_LPD  @0x8000_0000 (16 MB device aperture)
//   S_AXI_STAT (AXI4-Lite) <- PS M_AXI_HPM0_LPD  @0x8001_0000 (status sideband)
//   M_AXI_FB   (AXI4)      -> PS S_AXI_HP0_FPD              (framebuffer DRAM)
// Single clock (clk) / synchronous reset (rst_n) — no host-port CDC. Build with
// VOODOO_INT + VOODOO_FB_DDR + VOODOO_TEX_AW=17 (texture -> URAM, FB -> DDR4).
`default_nettype none

module voodoo_pl_top
  import voodoo_pkg::*;
(
    input  wire logic        clk,
    input  wire logic        rst_n,

    // S_AXI_BAR (AXI4, 24-bit addr, 32-bit data)
    input  wire logic [23:0] s_bar_awaddr,  input wire logic [7:0] s_bar_awlen,
    input  wire logic [2:0]  s_bar_awsize,  input wire logic [1:0] s_bar_awburst,
    input  wire logic        s_bar_awvalid, output wire logic      s_bar_awready,
    input  wire logic [31:0] s_bar_wdata,   input wire logic [3:0] s_bar_wstrb,
    input  wire logic        s_bar_wlast,   input wire logic       s_bar_wvalid,
    output wire logic        s_bar_wready,
    output wire logic [1:0]  s_bar_bresp,   output wire logic      s_bar_bvalid,
    input  wire logic        s_bar_bready,
    input  wire logic [23:0] s_bar_araddr,  input wire logic [7:0] s_bar_arlen,
    input  wire logic [2:0]  s_bar_arsize,  input wire logic [1:0] s_bar_arburst,
    input  wire logic        s_bar_arvalid, output wire logic      s_bar_arready,
    output wire logic [31:0] s_bar_rdata,   output wire logic [1:0] s_bar_rresp,
    output wire logic        s_bar_rlast,   output wire logic      s_bar_rvalid,
    input  wire logic        s_bar_rready,

    // S_AXI_STAT (AXI4-Lite, 8-bit addr, 32-bit data)
    input  wire logic [7:0]  s_stat_awaddr, input wire logic       s_stat_awvalid,
    output wire logic        s_stat_awready,
    input  wire logic [31:0] s_stat_wdata,  input wire logic [3:0] s_stat_wstrb,
    input  wire logic        s_stat_wvalid, output wire logic      s_stat_wready,
    output wire logic [1:0]  s_stat_bresp,  output wire logic      s_stat_bvalid,
    input  wire logic        s_stat_bready,
    input  wire logic [7:0]  s_stat_araddr, input wire logic       s_stat_arvalid,
    output wire logic        s_stat_arready,
    output wire logic [31:0] s_stat_rdata,  output wire logic [1:0] s_stat_rresp,
    output wire logic        s_stat_rvalid, input wire logic       s_stat_rready,

    // M_AXI_FB (AXI4 master -> PS S_AXI_HP, 32-bit data)
    output wire logic [48:0] m_axi_fb_awaddr,  output wire logic [7:0] m_axi_fb_awlen,
    output wire logic [2:0]  m_axi_fb_awsize,  output wire logic [1:0] m_axi_fb_awburst,
    output wire logic        m_axi_fb_awvalid, input  wire logic       m_axi_fb_awready,
    output wire logic [31:0] m_axi_fb_wdata,   output wire logic [3:0] m_axi_fb_wstrb,
    output wire logic        m_axi_fb_wlast,   output wire logic       m_axi_fb_wvalid,
    input  wire logic        m_axi_fb_wready,
    input  wire logic [1:0]  m_axi_fb_bresp,   input  wire logic       m_axi_fb_bvalid,
    output wire logic        m_axi_fb_bready,
    output wire logic [48:0] m_axi_fb_araddr,  output wire logic [7:0] m_axi_fb_arlen,
    output wire logic [2:0]  m_axi_fb_arsize,  output wire logic [1:0] m_axi_fb_arburst,
    output wire logic        m_axi_fb_arvalid, input  wire logic       m_axi_fb_arready,
    input  wire logic [31:0] m_axi_fb_rdata,   input  wire logic [1:0] m_axi_fb_rresp,
    input  wire logic        m_axi_fb_rlast,   input  wire logic       m_axi_fb_rvalid,
    output wire logic        m_axi_fb_rready
);
  // host port between the AXI slave and voodoo_top
  logic        hw_wr_valid, hw_wr_ready, hw_rd_valid, hw_rd_ready, hw_rd_resp_valid;
  logic [23:2] hw_wr_addr, hw_rd_addr;
  logic [31:0] hw_wr_data, hw_rd_data, hw_init_enable;
  logic [3:0]  hw_wr_be;
  logic        hw_busy;
  logic [1:0]  hw_frontbuf;
  logic [FB_AW-1:0] hw_scan_base;
  logic [10:0] hw_scan_rowpixels;
  logic [9:0]  hw_scan_width, hw_scan_height;

  axi_voodoo_slave u_slave (
      .clk(clk), .rst_n(rst_n),
      .s_bar_awaddr(s_bar_awaddr), .s_bar_awlen(s_bar_awlen), .s_bar_awsize(s_bar_awsize),
      .s_bar_awburst(s_bar_awburst), .s_bar_awvalid(s_bar_awvalid), .s_bar_awready(s_bar_awready),
      .s_bar_wdata(s_bar_wdata), .s_bar_wstrb(s_bar_wstrb), .s_bar_wlast(s_bar_wlast),
      .s_bar_wvalid(s_bar_wvalid), .s_bar_wready(s_bar_wready),
      .s_bar_bresp(s_bar_bresp), .s_bar_bvalid(s_bar_bvalid), .s_bar_bready(s_bar_bready),
      .s_bar_araddr(s_bar_araddr), .s_bar_arlen(s_bar_arlen), .s_bar_arsize(s_bar_arsize),
      .s_bar_arburst(s_bar_arburst), .s_bar_arvalid(s_bar_arvalid), .s_bar_arready(s_bar_arready),
      .s_bar_rdata(s_bar_rdata), .s_bar_rresp(s_bar_rresp), .s_bar_rlast(s_bar_rlast),
      .s_bar_rvalid(s_bar_rvalid), .s_bar_rready(s_bar_rready),
      .s_stat_awaddr(s_stat_awaddr), .s_stat_awvalid(s_stat_awvalid), .s_stat_awready(s_stat_awready),
      .s_stat_wdata(s_stat_wdata), .s_stat_wstrb(s_stat_wstrb), .s_stat_wvalid(s_stat_wvalid),
      .s_stat_wready(s_stat_wready), .s_stat_bresp(s_stat_bresp), .s_stat_bvalid(s_stat_bvalid),
      .s_stat_bready(s_stat_bready), .s_stat_araddr(s_stat_araddr), .s_stat_arvalid(s_stat_arvalid),
      .s_stat_arready(s_stat_arready), .s_stat_rdata(s_stat_rdata), .s_stat_rresp(s_stat_rresp),
      .s_stat_rvalid(s_stat_rvalid), .s_stat_rready(s_stat_rready),
      .host_wr_valid(hw_wr_valid), .host_wr_ready(hw_wr_ready), .host_wr_addr(hw_wr_addr),
      .host_wr_data(hw_wr_data), .host_wr_be(hw_wr_be),
      .host_rd_valid(hw_rd_valid), .host_rd_ready(hw_rd_ready), .host_rd_addr(hw_rd_addr),
      .host_rd_resp_valid(hw_rd_resp_valid), .host_rd_data(hw_rd_data),
      .init_enable(hw_init_enable), .busy(hw_busy), .dbg_frontbuf(hw_frontbuf),
      .scan_front_base(hw_scan_base), .scan_rowpixels(hw_scan_rowpixels),
      .scan_width(hw_scan_width), .scan_height(hw_scan_height));

  voodoo_top u_core (
      .clk(clk), .rst_n(rst_n),
      .host_wr_valid(hw_wr_valid), .host_wr_ready(hw_wr_ready), .host_wr_addr(hw_wr_addr),
      .host_wr_data(hw_wr_data), .host_wr_be(hw_wr_be),
      .host_rd_valid(hw_rd_valid), .host_rd_ready(hw_rd_ready), .host_rd_addr(hw_rd_addr),
      .host_rd_resp_valid(hw_rd_resp_valid), .host_rd_data(hw_rd_data),
      .init_enable(hw_init_enable), .busy(hw_busy), .dbg_frontbuf(hw_frontbuf),
      .scan_front_base(hw_scan_base), .scan_rowpixels(hw_scan_rowpixels),
      .scan_width(hw_scan_width), .scan_height(hw_scan_height),
      .m_axi_fb_awaddr(m_axi_fb_awaddr), .m_axi_fb_awlen(m_axi_fb_awlen), .m_axi_fb_awsize(m_axi_fb_awsize),
      .m_axi_fb_awburst(m_axi_fb_awburst), .m_axi_fb_awvalid(m_axi_fb_awvalid), .m_axi_fb_awready(m_axi_fb_awready),
      .m_axi_fb_wdata(m_axi_fb_wdata), .m_axi_fb_wstrb(m_axi_fb_wstrb), .m_axi_fb_wlast(m_axi_fb_wlast),
      .m_axi_fb_wvalid(m_axi_fb_wvalid), .m_axi_fb_wready(m_axi_fb_wready),
      .m_axi_fb_bresp(m_axi_fb_bresp), .m_axi_fb_bvalid(m_axi_fb_bvalid), .m_axi_fb_bready(m_axi_fb_bready),
      .m_axi_fb_araddr(m_axi_fb_araddr), .m_axi_fb_arlen(m_axi_fb_arlen), .m_axi_fb_arsize(m_axi_fb_arsize),
      .m_axi_fb_arburst(m_axi_fb_arburst), .m_axi_fb_arvalid(m_axi_fb_arvalid), .m_axi_fb_arready(m_axi_fb_arready),
      .m_axi_fb_rdata(m_axi_fb_rdata), .m_axi_fb_rresp(m_axi_fb_rresp), .m_axi_fb_rlast(m_axi_fb_rlast),
      .m_axi_fb_rvalid(m_axi_fb_rvalid), .m_axi_fb_rready(m_axi_fb_rready));

endmodule

`default_nettype wire
