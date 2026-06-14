// lfb_unit.sv — CONTRACTS §8 M1 block: LFB raw writes (MAME internal_lfb_w /
// expand_lfb_data, formats 0,1,2,4,5,12,13,14,15 x rgba_lanes, swizzle/swap,
// conditional offset<<1, mem_mask/present interaction, y-flip, dithered RGB,
// alpha-planes vs depth aux, OOB drop §9.6, fbiPixelsOut) and LFB reads
// (MAME internal_lfb_r: rbufsel, y-flip, two pixels, read swaps).
module lfb_unit
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // write command from cmd_dispatch (held until wr_done pulses)
    input  logic        wr_valid,
    input  logic [19:0] wr_dwoff,
    input  logic [31:0] wr_data,
    input  logic [3:0]  wr_be,
    output logic        wr_done,

    // read command from cmd_dispatch (held until rd_done pulses)
    input  logic        rd_valid,
    input  logic [19:0] rd_dwoff,
    output logic        rd_done,
    output logic [31:0] rd_data,

    // live register state (stable while dispatch waits on this unit)
    input  logic [31:0] lfbmode,
    input  logic [31:0] fbzmode,
    input  logic [31:0] zacolor,
    input  logic [10:0] rowpixels,
    input  logic [9:0]  yorigin,
    input  logic [9:0]  height,
    input  logic [FB_AW-1:0] rgboffs_w [4],
    input  logic [3:0]       rgboffs_valid,
    input  logic [FB_AW-1:0] auxoffs_w,
    input  logic             auxoffs_valid,
    input  logic [1:0]  frontbuf,
    input  logic [1:0]  backbuf,

    // M4: extra mode regs for the LFB pixel-pipeline path (lfbMode bit8)
    input  logic [31:0] fbzcp,
    input  logic [31:0] alphamode,
    input  logic [31:0] fogmode,
    input  logic [31:0] color0,
    input  logic [31:0] color1,
    input  logic [31:0] chromakey,
    input  logic [31:0] fogcolor,
    input  logic [31:0] stipple,

    // M4: pixel-pipeline injection channel into pixel_pipe (lfbMode bit8)
    output logic        pp_ext_load,
    output tri_params_t pp_ext_tp,
    output logic        pp_ext_px_valid,
    input  logic        pp_ext_px_ready,
    output logic [9:0]  pp_ext_x,
    output logic [9:0]  pp_ext_y,
    output logic [7:0]  pp_ext_r, pp_ext_g, pp_ext_b, pp_ext_a,
    output logic [15:0] pp_ext_sz,
    output logic        pp_ext_wsel,
    input  logic        pp_ext_px_done,

    // fb_arb client 0 port (§7.3)
    output logic              req_valid,
    input  logic              req_ready,
    output logic              req_we,
    output logic [FB_AW-1:0]  req_addr,
    output logic [15:0]       req_wdata,
    input  logic              rsp_valid,
    input  logic [15:0]       rsp_rdata,

    // fbiPixelsOut increment (1-cycle count of present pixel slots)
    output logic [1:0]  pixout_cnt
);

  function automatic logic [7:0] rep5(input logic [4:0] v);
    return {v, v[4:2]};
  endfunction
  function automatic logic [7:0] rep6(input logic [5:0] v);
    return {v, v[5:4]};
  endfunction

  // ----------------------------------------------------------------
  // latched request
  // ----------------------------------------------------------------
  logic [19:0] dwoff_q;
  logic [31:0] data_q;
  logic [3:0]  be_q;
  logic        is_rd_q;

  // ----------------------------------------------------------------
  // write-data swizzle/swap (byte_swizzle_writes bit12, word_swap_writes bit11)
  // ----------------------------------------------------------------
  logic [31:0] wd;
  logic [3:0]  wbe;
  always_comb begin
    logic [31:0] t;
    logic [3:0]  tb;
    t  = lfbmode[12] ? {data_q[7:0], data_q[15:8], data_q[23:16], data_q[31:24]}
                     : data_q;
    tb = lfbmode[12] ? {be_q[0], be_q[1], be_q[2], be_q[3]} : be_q;
    wd  = lfbmode[11] ? {t[15:0], t[31:16]} : t;
    wbe = lfbmode[11] ? {tb[1:0], tb[3:2]} : tb;
  end

  // ----------------------------------------------------------------
  // expand_lfb_data (MAME 1719-1872): present mask bits, MAME encoding:
  // [0]=RGB0 [1]=ALPHA0 [2]=DEPTH0 [3]=DEPTH_MSW_0 [4]=RGB1 [5]=ALPHA1 [6]=DEPTH1
  // ----------------------------------------------------------------
  logic [7:0]  r0, g0, b0, a0, r1, g1, b1, a1;
  logic [15:0] d0, d1;
  logic [6:0]  pm_fmt;
  logic [3:0]  fmt;
  logic [1:0]  lanes;
  logic [15:0] lo, hi;

  always_comb begin
    fmt   = lfbmode[3:0];
    lanes = lfbmode[10:9];
    lo    = wd[15:0];
    hi    = wd[31:16];
    // defaults: depth from zaColor[15:0], alpha from zaColor[31:24]
    d0 = zacolor[15:0];
    d1 = zacolor[15:0];
    a0 = zacolor[31:24];
    a1 = zacolor[31:24];
    r0 = 8'h0; g0 = 8'h0; b0 = 8'h0;
    r1 = 8'h0; g1 = 8'h0; b1 = 8'h0;
    pm_fmt = 7'h00;
    unique case (fmt)
      4'd0: begin                                   // 16-bit RGB 5-6-5 x2
        if (lanes == 2'd0 || lanes == 2'd2) begin
          r0 = rep5(lo[15:11]); g0 = rep6(lo[10:5]); b0 = rep5(lo[4:0]);
          r1 = rep5(hi[15:11]); g1 = rep6(hi[10:5]); b1 = rep5(hi[4:0]);
        end else begin
          r0 = rep5(lo[4:0]); g0 = rep6(lo[10:5]); b0 = rep5(lo[15:11]);
          r1 = rep5(hi[4:0]); g1 = rep6(hi[10:5]); b1 = rep5(hi[15:11]);
        end
        pm_fmt = 7'b0010001;                        // RGB0 | RGB1
      end
      4'd1: begin                                   // 16-bit RGB x-5-5-5 x2
        unique case (lanes)
          2'd0: begin
            r0 = rep5(lo[14:10]); g0 = rep5(lo[9:5]);  b0 = rep5(lo[4:0]);
            r1 = rep5(hi[14:10]); g1 = rep5(hi[9:5]);  b1 = rep5(hi[4:0]);
          end
          2'd1: begin
            r0 = rep5(lo[4:0]);   g0 = rep5(lo[9:5]);  b0 = rep5(lo[14:10]);
            r1 = rep5(hi[4:0]);   g1 = rep5(hi[9:5]);  b1 = rep5(hi[14:10]);
          end
          2'd2: begin
            r0 = rep5(lo[15:11]); g0 = rep5(lo[10:6]); b0 = rep5(lo[5:1]);
            r1 = rep5(hi[15:11]); g1 = rep5(hi[10:6]); b1 = rep5(hi[5:1]);
          end
          default: begin
            r0 = rep5(lo[5:1]);   g0 = rep5(lo[10:6]); b0 = rep5(lo[15:11]);
            r1 = rep5(hi[5:1]);   g1 = rep5(hi[10:6]); b1 = rep5(hi[15:11]);
          end
        endcase
        pm_fmt = 7'b0010001;                        // RGB0 | RGB1
      end
      4'd2: begin                                   // 16-bit ARGB 1-5-5-5 x2
        unique case (lanes)
          2'd0: begin
            a0 = {8{lo[15]}}; r0 = rep5(lo[14:10]); g0 = rep5(lo[9:5]);  b0 = rep5(lo[4:0]);
            a1 = {8{hi[15]}}; r1 = rep5(hi[14:10]); g1 = rep5(hi[9:5]);  b1 = rep5(hi[4:0]);
          end
          2'd1: begin
            a0 = {8{lo[15]}}; r0 = rep5(lo[4:0]);   g0 = rep5(lo[9:5]);  b0 = rep5(lo[14:10]);
            a1 = {8{hi[15]}}; r1 = rep5(hi[4:0]);   g1 = rep5(hi[9:5]);  b1 = rep5(hi[14:10]);
          end
          2'd2: begin
            a0 = {8{lo[0]}};  r0 = rep5(lo[15:11]); g0 = rep5(lo[10:6]); b0 = rep5(lo[5:1]);
            a1 = {8{hi[0]}};  r1 = rep5(hi[15:11]); g1 = rep5(hi[10:6]); b1 = rep5(hi[5:1]);
          end
          default: begin
            a0 = {8{lo[0]}};  r0 = rep5(lo[5:1]);   g0 = rep5(lo[10:6]); b0 = rep5(lo[15:11]);
            a1 = {8{hi[0]}};  r1 = rep5(hi[5:1]);   g1 = rep5(hi[10:6]); b1 = rep5(hi[15:11]);
          end
        endcase
        pm_fmt = 7'b0110011;                        // RGB|ALPHA both pixels
      end
      4'd4: begin                                   // 32-bit RGB x-8-8-8
        unique case (lanes)
          2'd0:    begin r0 = wd[23:16]; g0 = wd[15:8];  b0 = wd[7:0];   end
          2'd1:    begin r0 = wd[7:0];   g0 = wd[15:8];  b0 = wd[23:16]; end
          2'd2:    begin r0 = wd[31:24]; g0 = wd[23:16]; b0 = wd[15:8];  end
          default: begin r0 = wd[15:8];  g0 = wd[23:16]; b0 = wd[31:24]; end
        endcase
        pm_fmt = 7'b0000001;                        // RGB0
      end
      4'd5: begin                                   // 32-bit ARGB 8-8-8-8
        unique case (lanes)
          2'd0:    begin a0 = wd[31:24]; r0 = wd[23:16]; g0 = wd[15:8];  b0 = wd[7:0];   end
          2'd1:    begin a0 = wd[31:24]; r0 = wd[7:0];   g0 = wd[15:8];  b0 = wd[23:16]; end
          2'd2:    begin a0 = wd[7:0];   r0 = wd[31:24]; g0 = wd[23:16]; b0 = wd[15:8];  end
          default: begin a0 = wd[7:0];   r0 = wd[15:8];  g0 = wd[23:16]; b0 = wd[31:24]; end
        endcase
        pm_fmt = 7'b0000011;                        // RGB0 | ALPHA0
      end
      4'd12: begin                                  // 32-bit depth + RGB 5-6-5
        if (lanes == 2'd0 || lanes == 2'd2) begin
          r0 = rep5(lo[15:11]); g0 = rep6(lo[10:5]); b0 = rep5(lo[4:0]);
        end else begin
          r0 = rep5(lo[4:0]); g0 = rep6(lo[10:5]); b0 = rep5(lo[15:11]);
        end
        d0 = hi;
        pm_fmt = 7'b0001001;                        // RGB0 | DEPTH_MSW_0
      end
      4'd13: begin                                  // 32-bit depth + RGB x-5-5-5
        unique case (lanes)
          2'd0:    begin r0 = rep5(lo[14:10]); g0 = rep5(lo[9:5]);  b0 = rep5(lo[4:0]);   end
          2'd1:    begin r0 = rep5(lo[4:0]);   g0 = rep5(lo[9:5]);  b0 = rep5(lo[14:10]); end
          2'd2:    begin r0 = rep5(lo[15:11]); g0 = rep5(lo[10:6]); b0 = rep5(lo[5:1]);   end
          default: begin r0 = rep5(lo[5:1]);   g0 = rep5(lo[10:6]); b0 = rep5(lo[15:11]); end
        endcase
        d0 = hi;
        pm_fmt = 7'b0001001;                        // RGB0 | DEPTH_MSW_0
      end
      4'd14: begin                                  // 32-bit depth + ARGB 1-5-5-5
        unique case (lanes)
          2'd0:    begin a0 = {8{lo[15]}}; r0 = rep5(lo[14:10]); g0 = rep5(lo[9:5]);  b0 = rep5(lo[4:0]);   end
          2'd1:    begin a0 = {8{lo[15]}}; r0 = rep5(lo[4:0]);   g0 = rep5(lo[9:5]);  b0 = rep5(lo[14:10]); end
          2'd2:    begin a0 = {8{lo[0]}};  r0 = rep5(lo[15:11]); g0 = rep5(lo[10:6]); b0 = rep5(lo[5:1]);   end
          default: begin a0 = {8{lo[0]}};  r0 = rep5(lo[5:1]);   g0 = rep5(lo[10:6]); b0 = rep5(lo[15:11]); end
        endcase
        d0 = hi;
        pm_fmt = 7'b0001011;                        // RGB0 | ALPHA0 | DEPTH_MSW_0
      end
      4'd15: begin                                  // 16-bit depth x2
        d0 = lo;
        d1 = hi;
        pm_fmt = 7'b1000100;                        // DEPTH0 | DEPTH1
      end
      default: pm_fmt = 7'h00;                      // reserved -> mask 0
    endcase
  end

  // mem_mask/present interaction (post offset-shift decision):
  // low half absent -> clear pixel-0 flags EXCEPT depth-MSW;
  // high half absent -> clear pixel-1 flags AND depth-MSW-0.
  logic [6:0] pm;
  always_comb begin
    pm = pm_fmt;
    if (wbe[1:0] == 2'b00) pm = pm & 7'b1111000;
    if (wbe[3:2] == 2'b00) pm = pm & 7'b0000111;
  end

  // ----------------------------------------------------------------
  // address path (shared by writes and reads)
  // ----------------------------------------------------------------
  logic               two_pix;
  logic [20:0]        off21;
  logic [10:0]        px_x0, px_x1;
  logic [9:0]         py;
  logic signed [11:0] scry;
  logic               sy_ok;
  logic [9:0]         yor_eff;

  logic [1:0]         dbidx;
  logic [FB_AW-1:0]   base_sel;
  logic               base_valid;

  logic [20:0]        rowmul;
  logic [21:0]        idx0, addr0c, addr1c, addr0a, addr1a;
  logic               ok0c, ok1c, ok0a, ok1a;

  always_comb begin
    two_pix = |pm_fmt[6:4];     // offset <<= 1 ONLY when PIXEL1 present
    off21   = (is_rd_q | two_pix) ? {dwoff_q, 1'b0} : {1'b0, dwoff_q};
    px_x0   = {1'b0, off21[9:0]};
    px_x1   = px_x0 + 11'd1;
    py      = off21[19:10];     // & 0x3ff

    yor_eff = (yorigin != 10'd0) ? yorigin : (height - 10'd1);
    scry    = lfbmode[13] ? ($signed({2'b00, yor_eff}) - $signed({2'b00, py}))
                          : $signed({2'b00, py});
    sy_ok   = (scry >= 12'sd0) && (scry <= 12'sd1023);

    // buffer select: writes use lfbMode[5:4] (0=front 1=back, 2/3 DROPPED
    // per MAME draw_buffer_indirect); reads use lfbMode[7:6]
    // (0=front 1=back 2=aux 3=invalid)
    dbidx = (lfbmode[5:4] == 2'd1) ? backbuf : frontbuf;
    if (is_rd_q) begin
      unique case (lfbmode[7:6])
        2'd0: begin base_sel = rgboffs_w[frontbuf]; base_valid = rgboffs_valid[frontbuf]; end
        2'd1: begin base_sel = rgboffs_w[backbuf];  base_valid = rgboffs_valid[backbuf];  end
        2'd2: begin base_sel = auxoffs_w;           base_valid = auxoffs_valid;           end
        default: begin base_sel = '0;               base_valid = 1'b0;                    end
      endcase
    end else begin
      base_sel   = rgboffs_w[dbidx];
      base_valid = rgboffs_valid[dbidx] & ~lfbmode[5];  // wbufsel 2/3: drop
    end

    rowmul = 21'(scry[9:0]) * 21'(rowpixels);
    idx0   = {1'b0, rowmul} + {11'b0, px_x0};
    addr0c = {1'b0, base_sel} + idx0;
    addr1c = addr0c + 22'd1;
    addr0a = {1'b0, auxoffs_w} + idx0;
    addr1a = addr0a + 22'd1;

    // OOB drop per CONTRACTS §9.6
    ok0c = sy_ok & ~addr0c[21];
    ok1c = sy_ok & ~addr1c[21];
    ok0a = sy_ok & ~addr0a[21];
    ok1a = sy_ok & ~addr1a[21];
  end

  // dithered RGB (pkg dither565; x = pixel x, y = post-flip scry)
  logic [15:0] c0_565, c1_565;
  always_comb begin
    c0_565 = dither565(r0, g0, b0, fbzmode[8], fbzmode[11],
                       px_x0[1:0], scry[1:0]);
    c1_565 = dither565(r1, g1, b1, fbzmode[8], fbzmode[11],
                       px_x1[1:0], scry[1:0]);
  end

  // aux write values/enables (alpha planes vs depth, CONTRACTS §8)
  logic        alpha_planes;
  logic        w0c, w0a, w1c, w1a;
  logic [15:0] aux0_val, aux1_val;
  always_comb begin
    alpha_planes = fbzmode[18];
    aux0_val = alpha_planes ? {8'h00, a0} : d0;
    aux1_val = alpha_planes ? {8'h00, a1} : d1;
    w0c = pm[0] & ok0c;
    w1c = pm[4] & ok1c;
    w0a = auxoffs_valid & (alpha_planes ? pm[1] : (pm[2] | pm[3])) & ok0a;
    w1a = auxoffs_valid & (alpha_planes ? pm[5] : pm[6]) & ok1a;
  end

  // ----------------------------------------------------------------
  // M4 LFB pixel-pipeline (lfbMode bit8): synthesize a tri_params with the
  // mode-register snapshot + LFB dest/aux and push the expanded src pixels.
  // gold lfb_pixel_pipeline uses the UNFLIPPED row y (pixel_pipe flips it via
  // fbzMode[17]); present-pixel selection uses the post-wbe present mask pm.
  // ----------------------------------------------------------------
  logic        pp_path;        // this write uses the pixel pipeline
  logic        pix0_present, pix1_present;
  tri_params_t ext_tp_c;
  always_comb begin
    pp_path      = lfbmode[8];
    pix0_present = |pm[3:0];
    pix1_present = |pm[6:4];

    ext_tp_c           = '0;
    ext_tp_c.fbzmode   = fbzmode;
    ext_tp_c.fbzcp     = fbzcp;
    ext_tp_c.alphamode = alphamode;
    ext_tp_c.fogmode   = fogmode;
    ext_tp_c.texmode   = 32'd0;          // no texturing on LFB writes
    ext_tp_c.color0    = color0;
    ext_tp_c.color1    = color1;
    ext_tp_c.zacolor   = zacolor;
    ext_tp_c.chromakey = chromakey;
    ext_tp_c.fogcolor  = fogcolor;
    ext_tp_c.stipple   = stipple;
    ext_tp_c.dest_base = base_sel;       // LFB wbufsel (lfbMode[5:4])
    ext_tp_c.aux_base  = auxoffs_w;
    ext_tp_c.aux_valid = auxoffs_valid;
    ext_tp_c.rowpixels = rowpixels;
    ext_tp_c.yorigin   = yor_eff;
  end

  // ----------------------------------------------------------------
  // FSM
  // ----------------------------------------------------------------
  typedef enum logic [3:0] {
    L_IDLE, L_WSET, L_P0C, L_P0A, L_P1C, L_P1A, L_FIN,
    L_RSET, L_RREQ0, L_RW0, L_RREQ1, L_RW1, L_RFIN,
    L_PPLOAD, L_PP0, L_PP1
  } lstate_e;

  lstate_e     state_q;
  logic [15:0] p0_q;
  logic [31:0] rdata_q;
  logic [1:0]  pixout_q;
  logic        pp_acc_q;       // current ext pixel has been accepted by pipe

  // assembled read dword with read swaps (word_swap_reads bit15,
  // byte_swizzle_reads bit16, in that order, per MAME internal_lfb_r)
  logic [31:0] rassm;
  always_comb begin
    logic [31:0] v;
    v = {rsp_rdata, p0_q};
    if (lfbmode[15]) v = {v[15:0], v[31:16]};
    if (lfbmode[16]) v = {v[7:0], v[15:8], v[23:16], v[31:24]};
    rassm = v;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q  <= L_IDLE;
      dwoff_q  <= '0;
      data_q   <= '0;
      be_q     <= '0;
      is_rd_q  <= 1'b0;
      p0_q     <= '0;
      rdata_q  <= '0;
      pixout_q <= 2'd0;
      pp_acc_q <= 1'b0;
    end else begin
      pixout_q <= 2'd0;
      // clear the per-pixel accept latch when entering a fresh push state
      if (state_q == L_PPLOAD)
        pp_acc_q <= 1'b0;
      else if ((state_q == L_PP0 || state_q == L_PP1) &&
               pp_ext_px_valid && pp_ext_px_ready)
        pp_acc_q <= 1'b1;
      if (pp_ext_px_done)
        pp_acc_q <= 1'b0;
      unique case (state_q)
        L_IDLE: begin
          if (wr_valid) begin
            dwoff_q <= wr_dwoff;
            data_q  <= wr_data;
            be_q    <= wr_be;
            is_rd_q <= 1'b0;
            state_q <= L_WSET;
          end else if (rd_valid) begin
            dwoff_q <= rd_dwoff;
            is_rd_q <= 1'b1;
            state_q <= L_RSET;
          end
        end
        // ---- write sequence ----
        L_WSET: begin
          if (!base_valid) begin
            state_q <= L_FIN;      // no dest buffer: whole write dropped
          end else if (pp_path) begin
            // M4 pixel-pipeline path: pixel_pipe counts fbiPixelsOut itself
            state_q <= L_PPLOAD;
          end else begin
            // raw path. fbiPixelsOut: once per present pixel slot (any mask)
            pixout_q <= {1'b0, |pm[3:0]} + {1'b0, |pm[6:4]};
            state_q  <= L_P0C;
          end
        end
        L_P0C: if (!w0c || req_ready) state_q <= L_P0A;
        L_P0A: if (!w0a || req_ready) state_q <= L_P1C;
        L_P1C: if (!w1c || req_ready) state_q <= L_P1A;
        L_P1A: if (!w1a || req_ready) state_q <= L_FIN;
        L_FIN: state_q <= L_IDLE;
        // ---- M4 pixel-pipeline write sequence ----
        // L_PPLOAD pulses pp_ext_load (latches ext_tp & sets LFB mode in the
        // pipe), then push present pixel 0, then present pixel 1, each waiting
        // for the pipe to retire it (pp_ext_px_done) before advancing.
        L_PPLOAD: state_q <= pix0_present ? L_PP0
                           : (pix1_present ? L_PP1 : L_FIN);
        L_PP0: if (pp_ext_px_done) state_q <= pix1_present ? L_PP1 : L_FIN;
        L_PP1: if (pp_ext_px_done) state_q <= L_FIN;
        // ---- read sequence ----
        L_RSET: begin
          if (!base_valid || !sy_ok || addr0c[21] || addr1c[21]) begin
            rdata_q <= 32'hffffffff;
            state_q <= L_RFIN;
          end else begin
            state_q <= L_RREQ0;
          end
        end
        L_RREQ0: if (req_ready) state_q <= L_RW0;
        L_RW0:   if (rsp_valid) begin p0_q <= rsp_rdata; state_q <= L_RREQ1; end
        L_RREQ1: if (req_ready) state_q <= L_RW1;
        L_RW1:   if (rsp_valid) begin rdata_q <= rassm; state_q <= L_RFIN; end
        L_RFIN:  state_q <= L_IDLE;
        default: state_q <= L_IDLE;
      endcase
    end
  end

  // ----------------------------------------------------------------
  // outputs
  // ----------------------------------------------------------------
  // M4 pixel-pipeline injection drive
  always_comb begin
    pp_ext_load     = (state_q == L_PPLOAD);
    pp_ext_tp       = ext_tp_c;
    pp_ext_px_valid = ((state_q == L_PP0) || (state_q == L_PP1)) & ~pp_acc_q;
    // pixel 1 (x+1) uses col1/d1; pixel 0 uses col0/d0 (gold col[(xx-x)&1])
    pp_ext_x    = (state_q == L_PP1) ? px_x1[9:0] : px_x0[9:0];
    pp_ext_y    = py;                    // unflipped row (pipe flips it)
    pp_ext_r    = (state_q == L_PP1) ? r1 : r0;
    pp_ext_g    = (state_q == L_PP1) ? g1 : g0;
    pp_ext_b    = (state_q == L_PP1) ? b1 : b0;
    pp_ext_a    = (state_q == L_PP1) ? a1 : a0;
    pp_ext_sz   = (state_q == L_PP1) ? d1 : d0;
    pp_ext_wsel = lfbmode[14];
  end

  always_comb begin
    req_valid = 1'b0;
    req_we    = 1'b0;
    req_addr  = '0;
    req_wdata = '0;
    wr_done   = 1'b0;
    rd_done   = 1'b0;
    rd_data   = rdata_q;
    unique case (state_q)
      L_P0C: begin
        req_valid = w0c; req_we = 1'b1;
        req_addr = addr0c[FB_AW-1:0]; req_wdata = c0_565;
      end
      L_P0A: begin
        req_valid = w0a; req_we = 1'b1;
        req_addr = addr0a[FB_AW-1:0]; req_wdata = aux0_val;
      end
      L_P1C: begin
        req_valid = w1c; req_we = 1'b1;
        req_addr = addr1c[FB_AW-1:0]; req_wdata = c1_565;
      end
      L_P1A: begin
        req_valid = w1a; req_we = 1'b1;
        req_addr = addr1a[FB_AW-1:0]; req_wdata = aux1_val;
      end
      L_FIN:   wr_done = 1'b1;
      L_RREQ0: begin req_valid = 1'b1; req_addr = addr0c[FB_AW-1:0]; end
      L_RREQ1: begin req_valid = 1'b1; req_addr = addr1c[FB_AW-1:0]; end
      L_RFIN:  rd_done = 1'b1;
      default: ;
    endcase
  end

  assign pixout_cnt = pixout_q;

  // intentionally unused input bits / intermediate bits:
  // off21[20] dropped by the y &= 0x3ff rule; px_x1 high bits only feed dither.
  // The LFB raw path consumes only a subset of fbzmode/zacolor; the rest are
  // forwarded verbatim into ext_tp for the pixel-pipeline path.
  logic unused_in;
  assign unused_in = &{1'b0, lfbmode[31:17],
                       fbzmode[31:19], fbzmode[17:12], fbzmode[10:9],
                       fbzmode[7:0], zacolor[23:16], off21[20], px_x1[10]};

endmodule
