// fb_ddr_adapter.sv — framebuffer memory port -> PS DDR4 (KV260 S_AXI_HP), as an
// AXI4 master. Drop-in for the on-chip fb_ram glue: presents fb_arb's RAM-side
// handshake (req_valid/ready, we/addr/wdata, rd_valid/rdata) and turns each 16-bit
// framebuffer word access into a 2-byte AXI transfer at FB_BASE_BYTES + word*2.
//
// Single PL clock (ACLK == voodoo clk == HP-port clock => NO CDC, per README §4).
// Single outstanding transaction (req_ready drops while busy): correct and in-order
// by construction. fb_arb already tolerates arbitrary read latency + back-pressure
// (proven by `make test-fblat`), so this works functionally; MULTI-OUTSTANDING and
// an async-FIFO CDC (if the HP port runs faster than the fabric) are perf follow-ons.
//
// Verification status: lint/elaboration-clean. Functional sign-off needs a Vivado
// AXI-VIP / DDR-model simulation (no DDR model in the Verilator flow). The fb-side
// behaviour it must match is already covered by test-fblat.
//
// 16-bit subword on a 32-bit AXI data bus via a NARROW transfer (A?SIZE=1, 2 bytes):
//   byte_addr = FB_BASE_BYTES + (word << 1)   (off-by-2x corrupts the image)
//   write: WDATA = {2{wdata}}, WSTRB = byte_addr[1] ? 4'b1100 : 4'b0011
//   read : rdata = byte_addr[1] ? RDATA[31:16] : RDATA[15:0]
`default_nettype none

module fb_ddr_adapter
  import voodoo_pkg::*;
#(
    parameter int          AXI_AW        = 49,            // S_AXI_HP address width
    parameter logic [48:0] FB_BASE_BYTES = 49'h7000_0000  // DDR fb region base (byte)
) (
    input  wire logic              clk,
    input  wire logic              rst_n,

    // ---- fb_arb RAM-side handshake (== voodoo_top fb memory port) ----
    input  wire logic              req_valid,
    output wire logic              req_ready,
    input  wire logic              we,
    input  wire logic [FB_AW-1:0]  addr,
    input  wire logic [15:0]       wdata,
    output wire logic              rd_valid,
    output wire logic [15:0]       rdata,

    // ---- AXI4 master to PS DDR (S_AXI_HP*), 32-bit data ----
    output wire logic [AXI_AW-1:0] m_axi_awaddr,
    output wire logic [7:0]        m_axi_awlen,
    output wire logic [2:0]        m_axi_awsize,
    output wire logic [1:0]        m_axi_awburst,
    output wire logic              m_axi_awvalid,
    input  wire logic              m_axi_awready,
    output wire logic [31:0]       m_axi_wdata,
    output wire logic [3:0]        m_axi_wstrb,
    output wire logic              m_axi_wlast,
    output wire logic              m_axi_wvalid,
    input  wire logic              m_axi_wready,
    input  wire logic [1:0]        m_axi_bresp,
    input  wire logic              m_axi_bvalid,
    output wire logic              m_axi_bready,
    output wire logic [AXI_AW-1:0] m_axi_araddr,
    output wire logic [7:0]        m_axi_arlen,
    output wire logic [2:0]        m_axi_arsize,
    output wire logic [1:0]        m_axi_arburst,
    output wire logic              m_axi_arvalid,
    input  wire logic              m_axi_arready,
    input  wire logic [31:0]       m_axi_rdata,
    input  wire logic [1:0]        m_axi_rresp,
    input  wire logic              m_axi_rlast,
    input  wire logic              m_axi_rvalid,
    output wire logic              m_axi_rready
);
  typedef enum logic [2:0] { S_IDLE, S_AW, S_W, S_B, S_AR, S_R } state_e;
  state_e             st;
  logic [AXI_AW-1:0]  baddr_q;       // latched byte address
  logic [15:0]        wdata_q;
  logic               rd_valid_q;
  logic [15:0]        rdata_q;

  wire [AXI_AW-1:0] byte_addr = FB_BASE_BYTES + {{(AXI_AW-FB_AW-1){1'b0}}, addr, 1'b0}; // base + word*2

  assign req_ready = (st == S_IDLE);

  // address/control (held from the latched request)
  assign m_axi_awaddr  = baddr_q;
  assign m_axi_araddr  = baddr_q;
  assign m_axi_awlen   = 8'd0;       // single beat
  assign m_axi_arlen   = 8'd0;
  assign m_axi_awsize  = 3'd1;       // 2 bytes (narrow)
  assign m_axi_arsize  = 3'd1;
  assign m_axi_awburst = 2'b01;      // INCR
  assign m_axi_arburst = 2'b01;
  assign m_axi_awvalid = (st == S_AW);
  assign m_axi_arvalid = (st == S_AR);
  assign m_axi_wdata   = {2{wdata_q}};                       // subword on both lanes
  assign m_axi_wstrb   = baddr_q[1] ? 4'b1100 : 4'b0011;     // select the 2 active bytes
  assign m_axi_wlast   = 1'b1;
  assign m_axi_wvalid  = (st == S_W);
  assign m_axi_bready  = (st == S_B);
  assign m_axi_rready  = (st == S_R);

  assign rd_valid = rd_valid_q;
  assign rdata    = rdata_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE; baddr_q <= '0; wdata_q <= '0;
      rd_valid_q <= 1'b0; rdata_q <= '0;
    end else begin
      rd_valid_q <= 1'b0;                       // 1-cycle pulse
      unique case (st)
        S_IDLE: if (req_valid) begin
          baddr_q <= byte_addr; wdata_q <= wdata;
          st <= we ? S_AW : S_AR;
        end
        S_AW: if (m_axi_awvalid & m_axi_awready) st <= S_W;   // AW accepted -> W
        S_W:  if (m_axi_wvalid  & m_axi_wready ) st <= S_B;   // W accepted  -> B
        S_B:  if (m_axi_bvalid) st <= S_IDLE;
        S_AR: if (m_axi_arvalid & m_axi_arready) st <= S_R;
        S_R: if (m_axi_rvalid) begin
          rdata_q    <= baddr_q[1] ? m_axi_rdata[31:16] : m_axi_rdata[15:0];
          rd_valid_q <= 1'b1;
          st         <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

  // tie-off: B/R response codes are not surfaced (an error path would need a
  // status register); single-beat so rlast is implied.
  wire _unused = &{1'b0, m_axi_bresp, m_axi_rresp, m_axi_rlast};

endmodule

`default_nettype wire
