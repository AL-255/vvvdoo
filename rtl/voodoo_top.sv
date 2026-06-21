// voodoo_top.sv — CONTRACTS §6: top level, verbatim ports, no parameters.
// Instantiates host_if -> cmd_dispatch -> {regfile, lfb_unit, tex_dl, fastfill,
// raster+pixel_pipe} with fb_arb onto u_fb_ram and tex_dl onto u_tex_ram.
module voodoo_top
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // Host BAR access (32-bit dword granularity)
    input  logic        host_wr_valid,
    output logic        host_wr_ready,
    input  logic [23:2] host_wr_addr,
    input  logic [31:0] host_wr_data,
    input  logic [3:0]  host_wr_be,      // byte enables (from trace mask)

    input  logic        host_rd_valid,
    output logic        host_rd_ready,
    input  logic [23:2] host_rd_addr,
    output logic        host_rd_resp_valid,  // 1-cycle pulse with data
    output logic [31:0] host_rd_data,

    input  logic [31:0] init_enable,     // PCI config 0x40 (op=2 in traces)

    output logic        busy,            // FIFO non-empty or any engine active
    output logic [1:0]  dbg_frontbuf,

    // Scanout descriptor (chip-pin level; for host/co-sim display readback).
    // scan_front_base = word offset of the displayed buffer in fb_ram.
    output logic [FB_AW-1:0] scan_front_base,
    output logic [10:0]      scan_rowpixels,
    output logic [9:0]       scan_width,
    output logic [9:0]       scan_height
`ifdef VOODOO_FB_DDR
    // KV260 board: framebuffer in PS DDR4 via an AXI4 master (-> PS S_AXI_HP).
    // (Leading commas so the default/sim port list is byte-for-byte unchanged.)
    , output logic [48:0] m_axi_fb_awaddr
    , output logic [7:0]  m_axi_fb_awlen
    , output logic [2:0]  m_axi_fb_awsize
    , output logic [1:0]  m_axi_fb_awburst
    , output logic        m_axi_fb_awvalid
    , input  logic        m_axi_fb_awready
    , output logic [31:0] m_axi_fb_wdata
    , output logic [3:0]  m_axi_fb_wstrb
    , output logic        m_axi_fb_wlast
    , output logic        m_axi_fb_wvalid
    , input  logic        m_axi_fb_wready
    , input  logic [1:0]  m_axi_fb_bresp
    , input  logic        m_axi_fb_bvalid
    , output logic        m_axi_fb_bready
    , output logic [48:0] m_axi_fb_araddr
    , output logic [7:0]  m_axi_fb_arlen
    , output logic [2:0]  m_axi_fb_arsize
    , output logic [1:0]  m_axi_fb_arburst
    , output logic        m_axi_fb_arvalid
    , input  logic        m_axi_fb_arready
    , input  logic [31:0] m_axi_fb_rdata
    , input  logic [1:0]  m_axi_fb_rresp
    , input  logic        m_axi_fb_rlast
    , input  logic        m_axi_fb_rvalid
    , output logic        m_axi_fb_rready
`endif
);

  // ----------------------------------------------------------------
  // inter-module wires
  // ----------------------------------------------------------------
  // host_if <-> cmd_dispatch
  logic        cmd_valid, cmd_pop, cmd_is_write;
  logic [23:2] cmd_addr;
  logic [31:0] cmd_data;
  logic [3:0]  cmd_be;
  logic        rd_resp_valid;
  logic [31:0] rd_resp_data;
  logic [6:0]  fifo_free;
  logic        fifo_nonempty;
  logic        dispatch_busy;

  // regfile
  logic        rf_wr_en, rf_swap;
  logic [7:0]  rf_wr_regnum, rf_rd_regnum;
  logic [31:0] rf_wr_data, rf_rd_data;
  logic        dec_swizzle_en, dec_alias_en;
  logic [31:0] status_value;
  logic [31:0] r_fbzmode, r_fbzcp, r_alphamode, r_fogmode, r_texmode, r_tlod;
  logic [31:0] r_lfbmode, r_color0, r_color1, r_zacolor, r_clip_lr, r_clip_yy;
  logic [31:0] r_texbaseaddr;
  logic [31:0] r_stipple, r_chromakey, r_fogcolor;
  // M4 fog-table read port (pixel_pipe -> regfile)
  logic [5:0]  fog_rd_idx;
  logic [7:0]  fog_rd_blend, fog_rd_delta;
  logic [15:0] r_vtx_ax, r_vtx_ay, r_vtx_bx, r_vtx_by, r_vtx_cx, r_vtx_cy;
  logic [31:0] r_startr, r_startg, r_startb, r_starta, r_startz;
  logic [31:0] r_drdx, r_dgdx, r_dbdx, r_dadx, r_dzdx;
  logic [31:0] r_drdy, r_dgdy, r_dbdy, r_dady, r_dzdy;
  logic signed [63:0] r_sh_s, r_sh_dsdx, r_sh_dsdy;
  logic signed [63:0] r_sh_t, r_sh_dtdx, r_sh_dtdy;
  logic signed [63:0] r_sh_w, r_sh_dwdx, r_sh_dwdy;
  logic [10:0] r_rowpixels;
  logic [9:0]  r_width, r_height, r_yorigin;
  logic [FB_AW-1:0] r_rgboffs_w [4];
  logic [3:0]       r_rgboffs_valid;
  logic [FB_AW-1:0] r_auxoffs_w;
  logic             r_auxoffs_valid;
  logic [1:0]       r_frontbuf, r_backbuf;
  logic [1:0]       pixout_cnt_lfb;

  // lfb_unit command channel
  logic        lfb_wr_valid, lfb_wr_done, lfb_rd_valid, lfb_rd_done;
  logic [19:0] lfb_wr_dwoff, lfb_rd_dwoff;
  logic [31:0] lfb_wr_data, lfb_rd_data;
  logic [3:0]  lfb_wr_be;

  // tex_dl command channel
  logic        tex_wr_valid, tex_wr_done;
  logic [20:0] tex_wr_dwoff;
  logic [31:0] tex_wr_data;

  // fastfill command channel
  logic        ff_go, ff_done;
  logic [9:0]  ff_clip_left, ff_clip_right, ff_clip_top, ff_clip_bottom;
  logic [31:0] ff_color1;
  logic [15:0] ff_zfill;
  logic        ff_dith_en, ff_dith_2x2, ff_rgb_en, ff_aux_en;
  logic [FB_AW-1:0] ff_dest_base, ff_aux_base;
  logic             ff_dest_valid, ff_aux_valid;
  logic [10:0] ff_rowpixels;

  // triangle launch / pixel stream (§7.2)
  logic        tri_valid, tri_ready, tri_done;
  tri_params_t tri_params;
  logic        px_valid, px_ready, px_last;
  logic [9:0]  px_x, px_y;
  logic signed [31:0] px_r, px_g, px_b, px_a, px_z;
  logic signed [63:0] px_w, px_s0, px_t0, px_w0;
  logic        pp_pixout_inc;

  // M4 LFB pixel-pipeline injection (lfb_unit -> pixel_pipe)
  logic        pp_ext_load, pp_ext_px_valid, pp_ext_px_ready, pp_ext_px_done;
  tri_params_t pp_ext_tp;
  logic [9:0]  pp_ext_x, pp_ext_y;
  logic [7:0]  pp_ext_r, pp_ext_g, pp_ext_b, pp_ext_a;
  logic [15:0] pp_ext_sz;
  logic        pp_ext_wsel;

  // pixel_pipe <-> tmu sample channel (§11b)
  logic        smp_valid, smp_ready, tex_valid, tex_ready;
  logic [63:0] smp_s0, smp_t0, smp_w0;
  logic [7:0]  tex_a, tex_r, tex_g, tex_b;
  logic [TEX_AW-1:0] trd_addr;
  logic [15:0] trd_data;
  logic        tmu_ready;
  // raster idle (raster's tri_ready) AND tmu_ready gate the launch handshake
  logic        raster_tri_ready;

  // fb_arb client ports (§7.3): 0=lfb_unit, 1=fastfill, 2=pixel_pipe
  logic              c0_req_valid, c0_req_ready, c0_req_we, c0_rsp_valid;
  logic [FB_AW-1:0]  c0_req_addr;
  logic [15:0]       c0_req_wdata, c0_rsp_rdata;
  logic              c1_req_valid, c1_req_ready, c1_req_we, c1_rsp_valid;
  logic [FB_AW-1:0]  c1_req_addr;
  logic [15:0]       c1_req_wdata, c1_rsp_rdata;
  logic              c2_req_valid, c2_req_ready, c2_req_we, c2_rsp_valid;
  logic [FB_AW-1:0]  c2_req_addr;
  logic [15:0]       c2_req_wdata, c2_rsp_rdata;

  // fb_ram / tex_ram. The fb memory port is a valid/ready handshake with a
  // separate read-data-valid so fb_arb drives either the on-chip 1-cycle fb_ram
  // (here) or the variable-latency PS-DDR4 adapter on the KV260 board.
  logic              ram_req_valid, ram_req_ready, ram_we, ram_rd_valid;
  logic [FB_AW-1:0]  ram_addr;
  logic [15:0]       ram_wdata, ram_rdata;
  logic              t_req_valid, t_req_we;
  logic [TEX_AW-1:0] t_req_addr;
  logic [15:0]       t_req_wdata;
  logic [1:0]        t_req_be;

  // ----------------------------------------------------------------
  // top-level status
  // ----------------------------------------------------------------
  assign busy         = fifo_nonempty | dispatch_busy;
  assign dbg_frontbuf = r_frontbuf;

  // scanout descriptor: displayed buffer = rgboffs_w[frontbuf]
  assign scan_front_base = r_rgboffs_w[r_frontbuf];
  assign scan_rowpixels  = r_rowpixels;
  assign scan_width      = r_width;
  assign scan_height     = r_height;

  // ----------------------------------------------------------------
  // host interface
  // ----------------------------------------------------------------
  host_if u_host_if (
      .clk                (clk),
      .rst_n              (rst_n),
      .host_wr_valid      (host_wr_valid),
      .host_wr_ready      (host_wr_ready),
      .host_wr_addr       (host_wr_addr),
      .host_wr_data       (host_wr_data),
      .host_wr_be         (host_wr_be),
      .host_rd_valid      (host_rd_valid),
      .host_rd_ready      (host_rd_ready),
      .host_rd_addr       (host_rd_addr),
      .host_rd_resp_valid (host_rd_resp_valid),
      .host_rd_data       (host_rd_data),
      .cmd_valid          (cmd_valid),
      .cmd_pop            (cmd_pop),
      .cmd_is_write       (cmd_is_write),
      .cmd_addr           (cmd_addr),
      .cmd_data           (cmd_data),
      .cmd_be             (cmd_be),
      .rd_resp_valid      (rd_resp_valid),
      .rd_resp_data       (rd_resp_data),
      .status_value       (status_value),
      .engines_busy       (dispatch_busy),
      .fifo_free          (fifo_free),
      .fifo_nonempty      (fifo_nonempty)
  );

  // ----------------------------------------------------------------
  // register file
  // ----------------------------------------------------------------
  voodoo_regfile u_regfile (
      .clk             (clk),
      .rst_n           (rst_n),
      .wr_en           (rf_wr_en),
      .wr_regnum       (rf_wr_regnum),
      .wr_data         (rf_wr_data),
      .swap_en         (rf_swap),
      .rd_regnum       (rf_rd_regnum),
      .rd_data         (rf_rd_data),
      .fifo_free       (fifo_free),
      .busy            (busy),
      .init_enable     (init_enable),
      .status_value    (status_value),
      .pixout_cnt_lfb  (pixout_cnt_lfb),
      .pixout_inc_pipe (pp_pixout_inc),
      .dec_swizzle_en  (dec_swizzle_en),
      .dec_alias_en    (dec_alias_en),
      .fog_rd_idx      (fog_rd_idx),
      .fog_rd_blend    (fog_rd_blend),
      .fog_rd_delta    (fog_rd_delta),
      .fbzmode         (r_fbzmode),
      .fbzcp           (r_fbzcp),
      .alphamode       (r_alphamode),
      .fogmode         (r_fogmode),
      .texmode         (r_texmode),
      .tlod            (r_tlod),
      .lfbmode         (r_lfbmode),
      .color0          (r_color0),
      .color1          (r_color1),
      .zacolor         (r_zacolor),
      .clip_lr         (r_clip_lr),
      .clip_yy         (r_clip_yy),
      .texbaseaddr     (r_texbaseaddr),
      .stipple         (r_stipple),
      .chromakey       (r_chromakey),
      .fogcolor        (r_fogcolor),
      .vtx_ax          (r_vtx_ax),
      .vtx_ay          (r_vtx_ay),
      .vtx_bx          (r_vtx_bx),
      .vtx_by          (r_vtx_by),
      .vtx_cx          (r_vtx_cx),
      .vtx_cy          (r_vtx_cy),
      .it_startr       (r_startr),
      .it_startg       (r_startg),
      .it_startb       (r_startb),
      .it_starta       (r_starta),
      .it_startz       (r_startz),
      .it_drdx         (r_drdx),
      .it_dgdx         (r_dgdx),
      .it_dbdx         (r_dbdx),
      .it_dadx         (r_dadx),
      .it_dzdx         (r_dzdx),
      .it_drdy         (r_drdy),
      .it_dgdy         (r_dgdy),
      .it_dbdy         (r_dbdy),
      .it_dady         (r_dady),
      .it_dzdy         (r_dzdy),
      .sh_s            (r_sh_s),
      .sh_dsdx         (r_sh_dsdx),
      .sh_dsdy         (r_sh_dsdy),
      .sh_t            (r_sh_t),
      .sh_dtdx         (r_sh_dtdx),
      .sh_dtdy         (r_sh_dtdy),
      .sh_w            (r_sh_w),
      .sh_dwdx         (r_sh_dwdx),
      .sh_dwdy         (r_sh_dwdy),
      .rowpixels       (r_rowpixels),
      .width           (r_width),
      .height          (r_height),
      .yorigin         (r_yorigin),
      .rgboffs_w       (r_rgboffs_w),
      .rgboffs_valid   (r_rgboffs_valid),
      .auxoffs_w       (r_auxoffs_w),
      .auxoffs_valid   (r_auxoffs_valid),
      .frontbuf        (r_frontbuf),
      .backbuf         (r_backbuf)
  );

  // ----------------------------------------------------------------
  // command dispatch
  // ----------------------------------------------------------------
  cmd_dispatch u_cmd_dispatch (
      .clk            (clk),
      .rst_n          (rst_n),
      .cmd_valid      (cmd_valid),
      .cmd_pop        (cmd_pop),
      .cmd_is_write   (cmd_is_write),
      .cmd_addr       (cmd_addr),
      .cmd_data       (cmd_data),
      .cmd_be         (cmd_be),
      .rd_resp_valid  (rd_resp_valid),
      .rd_resp_data   (rd_resp_data),
      .rf_wr_en       (rf_wr_en),
      .rf_wr_regnum   (rf_wr_regnum),
      .rf_wr_data     (rf_wr_data),
      .rf_swap        (rf_swap),
      .rf_rd_regnum   (rf_rd_regnum),
      .rf_rd_data     (rf_rd_data),
      .dec_swizzle_en (dec_swizzle_en),
      .dec_alias_en   (dec_alias_en),
      .fbzmode        (r_fbzmode),
      .fbzcp          (r_fbzcp),
      .alphamode      (r_alphamode),
      .fogmode        (r_fogmode),
      .texmode        (r_texmode),
      .tlod           (r_tlod),
      .color0         (r_color0),
      .color1         (r_color1),
      .zacolor        (r_zacolor),
      .clip_lr        (r_clip_lr),
      .clip_yy        (r_clip_yy),
      .stipple        (r_stipple),
      .chromakey      (r_chromakey),
      .fogcolor       (r_fogcolor),
      .vtx_ax         (r_vtx_ax),
      .vtx_ay         (r_vtx_ay),
      .vtx_bx         (r_vtx_bx),
      .vtx_by         (r_vtx_by),
      .vtx_cx         (r_vtx_cx),
      .vtx_cy         (r_vtx_cy),
      .it_startr      (r_startr),
      .it_startg      (r_startg),
      .it_startb      (r_startb),
      .it_starta      (r_starta),
      .it_startz      (r_startz),
      .it_drdx        (r_drdx),
      .it_dgdx        (r_dgdx),
      .it_dbdx        (r_dbdx),
      .it_dadx        (r_dadx),
      .it_dzdx        (r_dzdx),
      .it_drdy        (r_drdy),
      .it_dgdy        (r_dgdy),
      .it_dbdy        (r_dbdy),
      .it_dady        (r_dady),
      .it_dzdy        (r_dzdy),
      .sh_s           (r_sh_s),
      .sh_dsdx        (r_sh_dsdx),
      .sh_dsdy        (r_sh_dsdy),
      .sh_t           (r_sh_t),
      .sh_dtdx        (r_sh_dtdx),
      .sh_dtdy        (r_sh_dtdy),
      .sh_w           (r_sh_w),
      .sh_dwdx        (r_sh_dwdx),
      .sh_dwdy        (r_sh_dwdy),
      .rowpixels      (r_rowpixels),
      .width          (r_width),
      .height         (r_height),
      .yorigin        (r_yorigin),
      .rgboffs_w      (r_rgboffs_w),
      .rgboffs_valid  (r_rgboffs_valid),
      .auxoffs_w      (r_auxoffs_w),
      .auxoffs_valid  (r_auxoffs_valid),
      .frontbuf       (r_frontbuf),
      .backbuf        (r_backbuf),
      .lfb_wr_valid   (lfb_wr_valid),
      .lfb_wr_dwoff   (lfb_wr_dwoff),
      .lfb_wr_data    (lfb_wr_data),
      .lfb_wr_be      (lfb_wr_be),
      .lfb_wr_done    (lfb_wr_done),
      .lfb_rd_valid   (lfb_rd_valid),
      .lfb_rd_dwoff   (lfb_rd_dwoff),
      .lfb_rd_done    (lfb_rd_done),
      .lfb_rd_data    (lfb_rd_data),
      .tex_wr_valid   (tex_wr_valid),
      .tex_wr_dwoff   (tex_wr_dwoff),
      .tex_wr_data    (tex_wr_data),
      .tex_wr_done    (tex_wr_done),
      .ff_go          (ff_go),
      .ff_done        (ff_done),
      .ff_clip_left   (ff_clip_left),
      .ff_clip_right  (ff_clip_right),
      .ff_clip_top    (ff_clip_top),
      .ff_clip_bottom (ff_clip_bottom),
      .ff_color1      (ff_color1),
      .ff_zfill       (ff_zfill),
      .ff_dith_en     (ff_dith_en),
      .ff_dith_2x2    (ff_dith_2x2),
      .ff_rgb_en      (ff_rgb_en),
      .ff_aux_en      (ff_aux_en),
      .ff_dest_base   (ff_dest_base),
      .ff_dest_valid  (ff_dest_valid),
      .ff_aux_base    (ff_aux_base),
      .ff_aux_valid   (ff_aux_valid),
      .ff_rowpixels   (ff_rowpixels),
      .tri_valid      (tri_valid),
      .tri_ready      (tri_ready),
      .tri_params     (tri_params),
      .tri_done       (tri_done),
      .dispatch_busy  (dispatch_busy)
  );

  // ----------------------------------------------------------------
  // LFB unit (fb_arb client 0)
  // ----------------------------------------------------------------
  lfb_unit u_lfb_unit (
      .clk           (clk),
      .rst_n         (rst_n),
      .wr_valid      (lfb_wr_valid),
      .wr_dwoff      (lfb_wr_dwoff),
      .wr_data       (lfb_wr_data),
      .wr_be         (lfb_wr_be),
      .wr_done       (lfb_wr_done),
      .rd_valid      (lfb_rd_valid),
      .rd_dwoff      (lfb_rd_dwoff),
      .rd_done       (lfb_rd_done),
      .rd_data       (lfb_rd_data),
      .lfbmode       (r_lfbmode),
      .fbzmode       (r_fbzmode),
      .zacolor       (r_zacolor),
      .rowpixels     (r_rowpixels),
      .yorigin       (r_yorigin),
      .height        (r_height),
      .rgboffs_w     (r_rgboffs_w),
      .rgboffs_valid (r_rgboffs_valid),
      .auxoffs_w     (r_auxoffs_w),
      .auxoffs_valid (r_auxoffs_valid),
      .frontbuf      (r_frontbuf),
      .backbuf       (r_backbuf),
      .fbzcp         (r_fbzcp),
      .alphamode     (r_alphamode),
      .fogmode       (r_fogmode),
      .color0        (r_color0),
      .color1        (r_color1),
      .chromakey     (r_chromakey),
      .fogcolor      (r_fogcolor),
      .stipple       (r_stipple),
      .pp_ext_load     (pp_ext_load),
      .pp_ext_tp       (pp_ext_tp),
      .pp_ext_px_valid (pp_ext_px_valid),
      .pp_ext_px_ready (pp_ext_px_ready),
      .pp_ext_x        (pp_ext_x),
      .pp_ext_y        (pp_ext_y),
      .pp_ext_r        (pp_ext_r),
      .pp_ext_g        (pp_ext_g),
      .pp_ext_b        (pp_ext_b),
      .pp_ext_a        (pp_ext_a),
      .pp_ext_sz       (pp_ext_sz),
      .pp_ext_wsel     (pp_ext_wsel),
      .pp_ext_px_done  (pp_ext_px_done),
      .req_valid     (c0_req_valid),
      .req_ready     (c0_req_ready),
      .req_we        (c0_req_we),
      .req_addr      (c0_req_addr),
      .req_wdata     (c0_req_wdata),
      .rsp_valid     (c0_rsp_valid),
      .rsp_rdata     (c0_rsp_rdata),
      .pixout_cnt    (pixout_cnt_lfb)
  );

  // ----------------------------------------------------------------
  // fastfill (fb_arb client 1)
  // ----------------------------------------------------------------
  fastfill u_fastfill (
      .clk         (clk),
      .rst_n       (rst_n),
      .go          (ff_go),
      .done        (ff_done),
      .clip_left   (ff_clip_left),
      .clip_right  (ff_clip_right),
      .clip_top    (ff_clip_top),
      .clip_bottom (ff_clip_bottom),
      .color1      (ff_color1),
      .zfill       (ff_zfill),
      .dith_en     (ff_dith_en),
      .dith_2x2    (ff_dith_2x2),
      .rgb_en      (ff_rgb_en),
      .aux_en      (ff_aux_en),
      .dest_base   (ff_dest_base),
      .dest_valid  (ff_dest_valid),
      .aux_base    (ff_aux_base),
      .aux_valid   (ff_aux_valid),
      .rowpixels   (ff_rowpixels),
      .req_valid   (c1_req_valid),
      .req_ready   (c1_req_ready),
      .req_we      (c1_req_we),
      .req_addr    (c1_req_addr),
      .req_wdata   (c1_req_wdata),
      .rsp_valid   (c1_rsp_valid),
      .rsp_rdata   (c1_rsp_rdata)
  );

  // ----------------------------------------------------------------
  // texture download -> tex_ram (single client, always ready)
  // ----------------------------------------------------------------
  tex_dl u_tex_dl (
      .clk         (clk),
      .rst_n       (rst_n),
      .wr_valid    (tex_wr_valid),
      .wr_dwoff    (tex_wr_dwoff),
      .wr_data     (tex_wr_data),
      .wr_done     (tex_wr_done),
      .texmode     (r_texmode),
      .tlod        (r_tlod),
      .texbaseaddr (r_texbaseaddr),
      .req_valid   (t_req_valid),
      .req_ready   (1'b1),
      .req_we      (t_req_we),
      .req_addr    (t_req_addr),
      .req_wdata   (t_req_wdata),
      .req_be      (t_req_be)
  );

  // ----------------------------------------------------------------
  // raster + pixel pipe ([raster agent], §7 interfaces)
  // ----------------------------------------------------------------
  // launch handshake: a triangle launches only when BOTH the raster and the
  // TMU can accept it (CONTRACTS §11b: AND their readies). tri_ready is what
  // cmd_dispatch / host see; pixel_pipe, raster and tmu all observe it.
  assign tri_ready = raster_tri_ready & tmu_ready;

  raster u_raster (
      .clk        (clk),
      .rst_n      (rst_n),
      .tri_valid  (tri_valid),
      .tri_ready  (raster_tri_ready),
      .tri_params (tri_params),
      .px_valid   (px_valid),
      .px_ready   (px_ready),
      .px_last    (px_last),
      .px_x       (px_x),
      .px_y       (px_y),
      .px_r       (px_r),
      .px_g       (px_g),
      .px_b       (px_b),
      .px_a       (px_a),
      .px_z       (px_z),
      .px_w       (px_w),
      .px_s0      (px_s0),
      .px_t0      (px_t0),
      .px_w0      (px_w0)
  );

  pixel_pipe u_pixel_pipe (
      .clk        (clk),
      .rst_n      (rst_n),
      .tri_valid  (tri_valid),
      .tri_ready  (tri_ready),
      .tri_params (tri_params),
      .px_valid   (px_valid),
      .px_ready   (px_ready),
      .px_last    (px_last),
      .px_x       (px_x),
      .px_y       (px_y),
      .px_r       (px_r),
      .px_g       (px_g),
      .px_b       (px_b),
      .px_a       (px_a),
      .px_z       (px_z),
      .px_w       (px_w),
      .px_s0      (px_s0),
      .px_t0      (px_t0),
      .px_w0      (px_w0),
      .tri_done   (tri_done),
      .ext_load     (pp_ext_load),
      .ext_tp       (pp_ext_tp),
      .ext_px_valid (pp_ext_px_valid),
      .ext_px_ready (pp_ext_px_ready),
      .ext_x        (pp_ext_x),
      .ext_y        (pp_ext_y),
      .ext_r        (pp_ext_r),
      .ext_g        (pp_ext_g),
      .ext_b        (pp_ext_b),
      .ext_a        (pp_ext_a),
      .ext_sz       (pp_ext_sz),
      .ext_wsel     (pp_ext_wsel),
      .ext_px_done  (pp_ext_px_done),
      .fog_rd_idx   (fog_rd_idx),
      .fog_rd_blend (fog_rd_blend),
      .fog_rd_delta (fog_rd_delta),
      .req_valid  (c2_req_valid),
      .req_ready  (c2_req_ready),
      .req_we     (c2_req_we),
      .req_addr   (c2_req_addr),
      .req_wdata  (c2_req_wdata),
      .rsp_valid  (c2_rsp_valid),
      .rsp_rdata  (c2_rsp_rdata),
      .smp_valid  (smp_valid),
      .smp_ready  (smp_ready),
      .smp_s0     (smp_s0),
      .smp_t0     (smp_t0),
      .smp_w0     (smp_w0),
      .tex_valid  (tex_valid),
      .tex_ready  (tex_ready),
      .tex_a      (tex_a),
      .tex_r      (tex_r),
      .tex_g      (tex_g),
      .tex_b      (tex_b),
      .pixout_inc (pp_pixout_inc)
  );

  // ----------------------------------------------------------------
  // texture mapping unit (M3) — between pixel_pipe and tex_ram read port
  // ----------------------------------------------------------------
  tmu u_tmu (
      .clk         (clk),
      .rst_n       (rst_n),
      .tri_valid   (tri_valid),
      .tri_ready   (tri_ready),
      .tri_params  (tri_params),
      .texbaseaddr (r_texbaseaddr),
      .tmu_ready   (tmu_ready),
      .smp_valid   (smp_valid),
      .smp_ready   (smp_ready),
      .smp_s0      (smp_s0),
      .smp_t0      (smp_t0),
      .smp_w0      (smp_w0),
      .tex_valid   (tex_valid),
      .tex_ready   (tex_ready),
      .tex_a       (tex_a),
      .tex_r       (tex_r),
      .tex_g       (tex_g),
      .tex_b       (tex_b),
      .trd_addr    (trd_addr),
      .trd_data    (trd_data)
  );

  // ----------------------------------------------------------------
  // framebuffer arbiter + RAMs (u_fb_ram / u_tex_ram at top level, §6)
  // ----------------------------------------------------------------
  fb_arb u_fb_arb (
      .clk          (clk),
      .rst_n        (rst_n),
      .c0_req_valid (c0_req_valid),
      .c0_req_ready (c0_req_ready),
      .c0_req_we    (c0_req_we),
      .c0_req_addr  (c0_req_addr),
      .c0_req_wdata (c0_req_wdata),
      .c0_rsp_valid (c0_rsp_valid),
      .c0_rsp_rdata (c0_rsp_rdata),
      .c1_req_valid (c1_req_valid),
      .c1_req_ready (c1_req_ready),
      .c1_req_we    (c1_req_we),
      .c1_req_addr  (c1_req_addr),
      .c1_req_wdata (c1_req_wdata),
      .c1_rsp_valid (c1_rsp_valid),
      .c1_rsp_rdata (c1_rsp_rdata),
      .c2_req_valid (c2_req_valid),
      .c2_req_ready (c2_req_ready),
      .c2_req_we    (c2_req_we),
      .c2_req_addr  (c2_req_addr),
      .c2_req_wdata (c2_req_wdata),
      .c2_rsp_valid (c2_rsp_valid),
      .c2_rsp_rdata (c2_rsp_rdata),
      .ram_req_valid (ram_req_valid),
      .ram_req_ready (ram_req_ready),
      .ram_we        (ram_we),
      .ram_addr      (ram_addr),
      .ram_wdata     (ram_wdata),
      .ram_rd_valid  (ram_rd_valid),
      .ram_rdata     (ram_rdata)
  );

`ifdef VOODOO_FB_DDR
  // ---- KV260 BOARD: framebuffer in PS DDR4 (no on-chip fb_ram) ----
  // fb_ddr_adapter masters PS S_AXI_HP; its handshake matches fb_arb's RAM port.
  // Verified functionally by `make test-fbddr` (adapter + behavioral AXI memory).
  fb_ddr_adapter #(.AXI_AW(49), .FB_BASE_BYTES(49'h7000_0000)) u_fbddr (
      .clk(clk), .rst_n(rst_n),
      .req_valid(ram_req_valid), .req_ready(ram_req_ready), .we(ram_we),
      .addr(ram_addr), .wdata(ram_wdata), .rd_valid(ram_rd_valid), .rdata(ram_rdata),
      .m_axi_awaddr(m_axi_fb_awaddr), .m_axi_awlen(m_axi_fb_awlen), .m_axi_awsize(m_axi_fb_awsize),
      .m_axi_awburst(m_axi_fb_awburst), .m_axi_awvalid(m_axi_fb_awvalid), .m_axi_awready(m_axi_fb_awready),
      .m_axi_wdata(m_axi_fb_wdata), .m_axi_wstrb(m_axi_fb_wstrb), .m_axi_wlast(m_axi_fb_wlast),
      .m_axi_wvalid(m_axi_fb_wvalid), .m_axi_wready(m_axi_fb_wready),
      .m_axi_bresp(m_axi_fb_bresp), .m_axi_bvalid(m_axi_fb_bvalid), .m_axi_bready(m_axi_fb_bready),
      .m_axi_araddr(m_axi_fb_araddr), .m_axi_arlen(m_axi_fb_arlen), .m_axi_arsize(m_axi_fb_arsize),
      .m_axi_arburst(m_axi_fb_arburst), .m_axi_arvalid(m_axi_fb_arvalid), .m_axi_arready(m_axi_fb_arready),
      .m_axi_rdata(m_axi_fb_rdata), .m_axi_rresp(m_axi_fb_rresp), .m_axi_rlast(m_axi_fb_rlast),
      .m_axi_rvalid(m_axi_fb_rvalid), .m_axi_rready(m_axi_fb_rready));
`else
  // u_fb_ram stays a direct child of voodoo_top (the trace-diff TB zero-fills
  // voodoo_top.u_fb_ram.mem by hierarchical path). The handshake glue around it
  // selects the memory-port behaviour; fb_ram's we/addr/wdata are muxed per build.
  logic [15:0]      fbram_rdata_raw, fbram_wdata;
  logic [FB_AW-1:0] fbram_addr;
  logic             fbram_we;
  fb_ram u_fb_ram (
      .clk   (clk),
      .we    (fbram_we),
      .addr  (fbram_addr),
      .wdata (fbram_wdata),
      .rdata (fbram_rdata_raw)
  );

`ifdef FB_DDR_SIM
  // SIM-ONLY: verify fb_ddr_adapter end-to-end. fb_arb -> fb_ddr_adapter (the real
  // AXI4 master) -> axi_mem_sim (behavioral AXI slave) -> fb_ram. Byte-identical
  // frames prove the adapter's AXI FSM, narrow-transfer addressing and lane muxing.
  // Build with `make test-fbddr`. NEVER synthesized.
  localparam int FBA = 49;
  logic [FBA-1:0] aw_a, ar_a;  logic [7:0] aw_l, ar_l;  logic [2:0] aw_s, ar_s;
  logic [1:0] aw_b, ar_b, b_r, r_r;
  logic aw_v, aw_rdy, w_v, w_rdy, w_l, b_v, b_rdy, ar_v, ar_rdy, r_v, r_rdy, r_l;
  logic [31:0] w_d, r_d;  logic [3:0] w_st;
  fb_ddr_adapter #(.AXI_AW(FBA), .FB_BASE_BYTES(49'd0)) u_fbddr (
      .clk(clk), .rst_n(rst_n),
      .req_valid(ram_req_valid), .req_ready(ram_req_ready), .we(ram_we),
      .addr(ram_addr), .wdata(ram_wdata), .rd_valid(ram_rd_valid), .rdata(ram_rdata),
      .m_axi_awaddr(aw_a), .m_axi_awlen(aw_l), .m_axi_awsize(aw_s), .m_axi_awburst(aw_b),
      .m_axi_awvalid(aw_v), .m_axi_awready(aw_rdy),
      .m_axi_wdata(w_d), .m_axi_wstrb(w_st), .m_axi_wlast(w_l), .m_axi_wvalid(w_v), .m_axi_wready(w_rdy),
      .m_axi_bresp(b_r), .m_axi_bvalid(b_v), .m_axi_bready(b_rdy),
      .m_axi_araddr(ar_a), .m_axi_arlen(ar_l), .m_axi_arsize(ar_s), .m_axi_arburst(ar_b),
      .m_axi_arvalid(ar_v), .m_axi_arready(ar_rdy),
      .m_axi_rdata(r_d), .m_axi_rresp(r_r), .m_axi_rlast(r_l), .m_axi_rvalid(r_v), .m_axi_rready(r_rdy));
  axi_mem_sim #(.AXI_AW(FBA)) u_axi_mem (
      .clk(clk), .rst_n(rst_n),
      .awaddr(aw_a), .awlen(aw_l), .awsize(aw_s), .awburst(aw_b), .awvalid(aw_v), .awready(aw_rdy),
      .wdata(w_d), .wstrb(w_st), .wlast(w_l), .wvalid(w_v), .wready(w_rdy),
      .bresp(b_r), .bvalid(b_v), .bready(b_rdy),
      .araddr(ar_a), .arlen(ar_l), .arsize(ar_s), .arburst(ar_b), .arvalid(ar_v), .arready(ar_rdy),
      .rdata(r_d), .rresp(r_r), .rlast(r_l), .rvalid(r_v), .rready(r_rdy),
      .mem_we(fbram_we), .mem_addr(fbram_addr), .mem_wdata(fbram_wdata), .mem_rdata(fbram_rdata_raw));
`elsif FB_LAT_INJECT
  assign fbram_addr  = ram_addr;
  assign fbram_wdata = ram_wdata;
  // SIM-ONLY DDR-readiness check: model a variable-latency, back-pressured memory
  // port (deterministic) and confirm the fb_arb tag FIFO + the lfb/fastfill/pixel
  // clients still produce byte-identical frames. Read responses are delayed in
  // program order by FB_RD_LAT cycles; req_ready drops 1 in 4 cycles. Build with
  // `make test-fblat`. NEVER synthesized (the board uses fb_ddr_adapter).
  // FB_RD_LAT > fb_arb TAG_DEPTH(16) so the tag-FIFO-full read backpressure path
  // is exercised (up to 20 responses in flight > 16 trackable -> ram_req_valid
  // must gate reads until a response retires).
  localparam int unsigned FB_RD_LAT = 20;
  logic [1:0] fbli_bp;
  always_ff @(posedge clk) fbli_bp <= !rst_n ? 2'd0 : fbli_bp + 2'd1;
  assign ram_req_ready = (fbli_bp != 2'b00);          // ready 3 of every 4 cycles
  wire   fbli_fire     = ram_req_valid & ram_req_ready;
  assign fbram_we      = fbli_fire & ram_we;          // write only when accepted

  // in-order {valid,data} delay line: dl[0] captures the read's data the cycle
  // fb_ram presents it (accept+1); dl[FB_RD_LAT] is the delivered response.
  logic         fbli_acc_rd;                          // read accepted last cycle
  logic         dl_v [0:FB_RD_LAT];
  logic [15:0]  dl_d [0:FB_RD_LAT];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fbli_acc_rd <= 1'b0;
      for (int k = 0; k <= FB_RD_LAT; k++) begin dl_v[k] <= 1'b0; dl_d[k] <= 16'h0; end
    end else begin
      fbli_acc_rd <= fbli_fire & ~ram_we;
      dl_v[0] <= fbli_acc_rd;  dl_d[0] <= fbram_rdata_raw;
      for (int k = 1; k <= FB_RD_LAT; k++) begin dl_v[k] <= dl_v[k-1]; dl_d[k] <= dl_d[k-1]; end
    end
  end
  assign ram_rd_valid = dl_v[FB_RD_LAT];
  assign ram_rdata    = dl_d[FB_RD_LAT];
`else
  // on-chip 1-cycle fb_ram as the handshake port: always ready, read data one cycle
  // later -> fb_arb's tag FIFO behaves identically to the legacy 1-deep pipe
  // (make test = PIXEL-EXACT). The KV260 board build swaps in fb_ddr_adapter.
  assign fbram_addr    = ram_addr;
  assign fbram_wdata   = ram_wdata;
  assign ram_req_ready = 1'b1;
  assign fbram_we      = ram_req_valid & ram_we;
  assign ram_rdata     = fbram_rdata_raw;
  always_ff @(posedge clk) begin
    if (!rst_n) ram_rd_valid <= 1'b0;
    else        ram_rd_valid <= ram_req_valid & ~ram_we;   // read accepted -> data next cycle
  end
`endif
`endif // VOODOO_FB_DDR

  tex_ram u_tex_ram (
      .clk     (clk),
      .we      (t_req_be & {2{t_req_valid & t_req_we}}),
      .addr    (t_req_addr),
      .wdata   (t_req_wdata),
      .addr_r  (trd_addr),
      .rdata_r (trd_data)
  );

endmodule
