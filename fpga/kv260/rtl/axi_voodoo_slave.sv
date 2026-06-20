// axi_voodoo_slave.sv — AXI4 slave wrapper bridging the KV260 PS to voodoo_top's
// custom host_wr_*/host_rd_* MMIO ports. KV260 board deployment (see
// fpga/kv260/README.md). voodoo_top is UNMODIFIED; this is a pure conduit.
//
// Two slave ports:
//   * S_AXI_BAR  (AXI4, 24-bit byte addr, 32-bit data) = the 16 MB device aperture
//     (regs @0 / LFB @4MB / texture @8MB). Region decode happens INSIDE voodoo_top
//     from host_addr[23:22]; the wrapper just passes A[23:2] through.
//   * S_AXI_STAT (AXI4-Lite, 8-bit byte addr) = a never-draining sideband exposing
//     busy / dbg_frontbuf / the scanout descriptor / init_enable. The software shim
//     polls busy and reads the scanout geometry HERE so it never triggers the BAR
//     read-drain (a non-status BAR read stalls until the whole FIFO + engines idle).
//
// Verified protocol points (kv260-board-groundwork adversarial review):
//   - RVALID is LATCHED and HELD across RREADY-low. host_rd_resp_valid is a 1-cycle
//     pulse; we capture host_rd_data into rdata_q and hold rvalid_q until R handshakes.
//     Never drive RVALID combinationally from the pulse.
//   - AR is accepted only when the previous R beat has retired (rvalid_q==0), not
//     merely when the device's rd_busy clears — else a new response overwrites the
//     held RDATA.
//   - The device is dword-only: AWSIZE!=3'b010 or a WRAP burst -> consume the beats
//     and return BRESP=SLVERR. WSTRB maps 1:1 to host_wr_be.
//   - WREADY is gated on host_wr_ready (registered = "FIFO not full"); B is posted
//     (OKAY = "queued", not "rendered" — use the STAT busy bit for completion).
`default_nettype none

module axi_voodoo_slave
  import voodoo_pkg::*;
(
    input  wire logic        clk,            // ACLK == voodoo clk (single domain)
    input  wire logic        rst_n,          // SYNCHRONOUS active-low (matches voodoo_top)

    // ---------- S_AXI_BAR : AXI4, 24-bit byte addr, 32-bit data ----------
    input  wire logic [23:0] s_bar_awaddr,
    input  wire logic [7:0]  s_bar_awlen,
    input  wire logic [2:0]  s_bar_awsize,
    input  wire logic [1:0]  s_bar_awburst,
    input  wire logic        s_bar_awvalid,
    output wire logic        s_bar_awready,
    input  wire logic [31:0] s_bar_wdata,
    input  wire logic [3:0]  s_bar_wstrb,
    input  wire logic        s_bar_wlast,
    input  wire logic        s_bar_wvalid,
    output wire logic        s_bar_wready,
    output wire logic [1:0]  s_bar_bresp,
    output wire logic        s_bar_bvalid,
    input  wire logic        s_bar_bready,
    input  wire logic [23:0] s_bar_araddr,
    input  wire logic [7:0]  s_bar_arlen,
    input  wire logic [2:0]  s_bar_arsize,
    input  wire logic [1:0]  s_bar_arburst,
    input  wire logic        s_bar_arvalid,
    output wire logic        s_bar_arready,
    output wire logic [31:0] s_bar_rdata,
    output wire logic [1:0]  s_bar_rresp,
    output wire logic        s_bar_rlast,
    output wire logic        s_bar_rvalid,
    input  wire logic        s_bar_rready,

    // ---------- S_AXI_STAT : AXI4-Lite, 8-bit byte addr, 32-bit data ----------
    input  wire logic [7:0]  s_stat_awaddr,
    input  wire logic        s_stat_awvalid,
    output wire logic        s_stat_awready,
    input  wire logic [31:0] s_stat_wdata,
    input  wire logic [3:0]  s_stat_wstrb,
    input  wire logic        s_stat_wvalid,
    output wire logic        s_stat_wready,
    output wire logic [1:0]  s_stat_bresp,
    output wire logic        s_stat_bvalid,
    input  wire logic        s_stat_bready,
    input  wire logic [7:0]  s_stat_araddr,
    input  wire logic        s_stat_arvalid,
    output wire logic        s_stat_arready,
    output wire logic [31:0] s_stat_rdata,
    output wire logic [1:0]  s_stat_rresp,
    output wire logic        s_stat_rvalid,
    input  wire logic        s_stat_rready,

    // ---------- to/from voodoo_top (its native host port) ----------
    output wire logic        host_wr_valid,
    input  wire logic        host_wr_ready,
    output wire logic [23:2] host_wr_addr,
    output wire logic [31:0] host_wr_data,
    output wire logic [3:0]  host_wr_be,
    output wire logic        host_rd_valid,
    input  wire logic        host_rd_ready,
    output wire logic [23:2] host_rd_addr,
    input  wire logic        host_rd_resp_valid,
    input  wire logic [31:0] host_rd_data,
    output wire logic [31:0] init_enable,
    input  wire logic        busy,
    input  wire logic [1:0]  dbg_frontbuf,
    input  wire logic [FB_AW-1:0] scan_front_base,
    input  wire logic [10:0] scan_rowpixels,
    input  wire logic [9:0]  scan_width,
    input  wire logic [9:0]  scan_height
);
  localparam logic [1:0] RESP_OKAY = 2'b00, RESP_SLVERR = 2'b10;

  // ============================ S_AXI_BAR write ============================
  typedef enum logic [1:0] { W_IDLE, W_DATA, W_RESP } wstate_e;
  wstate_e     wst_q;
  logic [23:2] w_addr_q;
  logic [7:0]  w_beats_q;
  logic        w_incr_q, w_bad_q;
  logic        bvalid_q;
  logic [1:0]  bresp_q;

  // push a beat into the device FIFO this cycle iff in W_DATA and the burst is legal
  wire w_push = (wst_q == W_DATA) & ~w_bad_q;
  assign host_wr_valid = w_push & s_bar_wvalid;
  assign host_wr_addr  = w_addr_q;
  assign host_wr_data  = s_bar_wdata;
  assign host_wr_be    = s_bar_wstrb;             // WSTRB -> byte enables, 1:1
  // accept the W beat when the FIFO accepts the push (good), or immediately (bad/drop)
  assign s_bar_wready  = (wst_q == W_DATA) & (w_bad_q ? 1'b1 : host_wr_ready);
  assign s_bar_awready = (wst_q == W_IDLE);
  assign s_bar_bvalid  = bvalid_q;
  assign s_bar_bresp   = bresp_q;

  wire w_beat = s_bar_wvalid & s_bar_wready;       // a W beat handshaked
  wire w_last = s_bar_wlast | (w_beats_q == 8'd0); // AWLEN backup if WLAST missing

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wst_q <= W_IDLE; w_addr_q <= '0; w_beats_q <= '0;
      w_incr_q <= 1'b0; w_bad_q <= 1'b0; bvalid_q <= 1'b0; bresp_q <= RESP_OKAY;
    end else begin
      unique case (wst_q)
        W_IDLE: if (s_bar_awvalid) begin
          w_addr_q  <= s_bar_awaddr[23:2];
          w_beats_q <= s_bar_awlen;
          w_incr_q  <= (s_bar_awburst == 2'b01);             // INCR
          w_bad_q   <= (s_bar_awsize != 3'b010) | (s_bar_awburst == 2'b10); // !dword | WRAP
          wst_q     <= W_DATA;
        end
        W_DATA: if (w_beat) begin
          if (w_incr_q) w_addr_q <= w_addr_q + 22'd1;        // dword increment
          w_beats_q <= w_beats_q - 8'd1;
          if (w_last) begin
            bresp_q  <= w_bad_q ? RESP_SLVERR : RESP_OKAY;
            bvalid_q <= 1'b1;
            wst_q    <= W_RESP;
          end
        end
        W_RESP: if (s_bar_bready) begin bvalid_q <= 1'b0; wst_q <= W_IDLE; end
        default: wst_q <= W_IDLE;
      endcase
    end
  end

  // ============================ S_AXI_BAR read =============================
  // Single outstanding read (the device allows one). Bursts handled serially.
  typedef enum logic [1:0] { R_IDLE, R_REQ, R_WAIT, R_RESP } rstate_e;
  rstate_e     rst_q;
  logic [23:2] r_addr_q;
  logic [7:0]  r_beats_q;
  logic        rvalid_q, rlast_q;
  logic [31:0] rdata_q;

  // accept AR only when idle AND the previous R beat has retired (no held RVALID)
  assign s_bar_arready = (rst_q == R_IDLE) & ~rvalid_q;
  assign host_rd_valid = (rst_q == R_REQ);
  assign host_rd_addr  = r_addr_q;
  assign s_bar_rvalid  = rvalid_q;
  assign s_bar_rdata   = rdata_q;
  assign s_bar_rlast   = rlast_q;
  assign s_bar_rresp   = RESP_OKAY;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rst_q <= R_IDLE; r_addr_q <= '0; r_beats_q <= '0;
      rvalid_q <= 1'b0; rlast_q <= 1'b0; rdata_q <= '0;
    end else begin
      unique case (rst_q)
        R_IDLE: if (s_bar_arvalid & s_bar_arready) begin
          r_addr_q  <= s_bar_araddr[23:2];
          r_beats_q <= s_bar_arlen;
          rst_q     <= R_REQ;
        end
        R_REQ: if (host_rd_ready) rst_q <= R_WAIT;          // device accepted the request
        R_WAIT: if (host_rd_resp_valid) begin               // 1-cycle data pulse -> latch+hold
          rdata_q  <= host_rd_data;
          rlast_q  <= (r_beats_q == 8'd0);
          rvalid_q <= 1'b1;
          rst_q    <= R_RESP;
        end
        R_RESP: if (rvalid_q & s_bar_rready) begin
          rvalid_q <= 1'b0;
          if (r_beats_q != 8'd0) begin
            r_beats_q <= r_beats_q - 8'd1;
            r_addr_q  <= r_addr_q + 22'd1;
            rst_q     <= R_REQ;
          end else rst_q <= R_IDLE;
        end
        default: rst_q <= R_IDLE;
      endcase
    end
  end

  // ===================== S_AXI_STAT (AXI4-Lite sideband) ====================
  logic [31:0] init_enable_q;
  assign init_enable = init_enable_q;

  // write (collect AW + W in any order, then post B)
  logic        st_aw_q, st_w_q, st_bvalid_q;
  logic [7:0]  st_waddr_q;
  logic [31:0] st_wdata_q;
  assign s_stat_awready = ~st_aw_q;
  assign s_stat_wready  = ~st_w_q;
  assign s_stat_bvalid  = st_bvalid_q;
  assign s_stat_bresp   = RESP_OKAY;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st_aw_q <= 1'b0; st_w_q <= 1'b0; st_bvalid_q <= 1'b0;
      st_waddr_q <= '0; st_wdata_q <= '0; init_enable_q <= '0;
    end else begin
      if (s_stat_awvalid & s_stat_awready) begin st_aw_q <= 1'b1; st_waddr_q <= s_stat_awaddr; end
      if (s_stat_wvalid  & s_stat_wready ) begin st_w_q  <= 1'b1; st_wdata_q <= s_stat_wdata;  end
      if (st_aw_q & st_w_q & ~st_bvalid_q) begin
        if (st_waddr_q[7:2] == 6'h06) init_enable_q <= st_wdata_q;  // 0x18 = INIT_ENABLE
        st_bvalid_q <= 1'b1; st_aw_q <= 1'b0; st_w_q <= 1'b0;
      end
      if (st_bvalid_q & s_stat_bready) st_bvalid_q <= 1'b0;
    end
  end

  // read (combinational mux of the status sources; never drains)
  logic        st_rvalid_q;
  logic [31:0] st_rdata_q;
  assign s_stat_arready = ~st_rvalid_q;
  assign s_stat_rvalid  = st_rvalid_q;
  assign s_stat_rdata   = st_rdata_q;
  assign s_stat_rresp   = RESP_OKAY;

  always_ff @(posedge clk) begin
    if (!rst_n) begin st_rvalid_q <= 1'b0; st_rdata_q <= '0; end
    else begin
      if (s_stat_arvalid & s_stat_arready) begin
        st_rvalid_q <= 1'b1;
        unique case (s_stat_araddr[4:2])
          3'd0: st_rdata_q <= {31'b0, busy};                                // 0x00 BUSY
          3'd1: st_rdata_q <= {30'b0, dbg_frontbuf};                        // 0x04 FRONTBUF
          3'd2: st_rdata_q <= {{(32-FB_AW){1'b0}}, scan_front_base};        // 0x08 FRONT_BASE (word)
          3'd3: st_rdata_q <= {21'b0, scan_rowpixels};                      // 0x0C ROWPIXELS
          3'd4: st_rdata_q <= {22'b0, scan_width};                          // 0x10 WIDTH
          3'd5: st_rdata_q <= {22'b0, scan_height};                         // 0x14 HEIGHT
          3'd6: st_rdata_q <= init_enable_q;                                // 0x18 INIT_ENABLE
          default: st_rdata_q <= 32'b0;
        endcase
      end
      if (st_rvalid_q & s_stat_rready) st_rvalid_q <= 1'b0;
    end
  end

  // tie-off: A[1:0] are always dropped (dword granularity), read size/burst are
  // ignored (device is dword), STAT WSTRB is full-dword, STAT addr is 8 regs.
  wire _unused = &{1'b0, s_bar_arsize, s_bar_arburst, s_stat_wstrb,
                   s_bar_awaddr[1:0], s_bar_araddr[1:0],
                   s_stat_araddr[7:5], s_stat_araddr[1:0], st_waddr_q[1:0]};

endmodule

`default_nettype wire
