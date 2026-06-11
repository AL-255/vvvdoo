// pixel_pipe.sv — [raster agent] per-pixel pipe, M2 scope (CONTRACTS §5/§7.2/§8).
//
// One pixel in flight, multi-cycle; bit-exact mirror of model/voodoo_gold.c
// pixel_pipe() (which itself ports MAME mame_voodoo_render.cpp semantics):
//   1) y-origin flip + CONTRACTS §9.6 out-of-range guard (separately for the
//      color and depth word addresses; gold fb_word_ok)
//   2) wfloat from the 16.32 W iterator <<16 (gold wfloat_of; MAME
//      compute_wfloat, mame_voodoo_render.cpp:66-74)
//   3) depth value (Z pseudo-clamp/saturate per fbzcp[28], gold clamped_z;
//      MAME clamped_z, mame_voodoo_render.cpp:117-132) or wfloat (fbzMode[3]),
//      depth bias (fbzMode[16], +sext16(zaColor), clamp 0..0xffff), depth
//      source compare (fbzMode[20] -> zaColor[15:0]); depth test (fbzMode[4],
//      func fbzMode[7:5]) against the stored aux word — skipped when the aux
//      buffer is absent or the aux address is out of range (gold pixel_pipe)
//   4) iterated ARGB clamp (gold clamp_argb_chan; MAME clamped_argb,
//      mame_voodoo_render.cpp:84-109)
//   5) color combine — full MAME combine_color (mame_voodoo_render.cpp:
//      1511-1729) as ported in gold combine_color_full; texel = constant
//      ARGB(255,255,255,255) in M2 (CONTRACTS §8); chroma key / alpha mask /
//      stipple / fog are M4 and slot in where marked
//   6) alpha test (alphaMode[0], func [3:1], ref [31:24])
//   7) alpha blend (alphaMode[4]; gold alpha_blend_full; MAME alpha_blend,
//      mame_voodoo_render.cpp:2009-2117): dst alpha = 255, A_COLOR factors
//      cross-reference dest(src side)/src(dst side) color, code 15 is
//      ASATURATE (src) / A_COLORBEFOREFOG (dst; == src color while fog is M4),
//      +1 scaling on codes 1,2,3,15; the dest pixel reads as 0 when its
//      address is out of range (gold pixel_pipe)
//   8) writes: color = dither565 to dest when fbzMode[9] and in range; aux =
//      alpha (fbzMode[18]) or depthval when fbzMode[10] and aux usable and in
//      range (exact gold condition — NOT gated by fbzMode[4]); fbiPixelsOut
//      pulses once per pixel reaching the write stage regardless of masks.
//
// A pixel failing any stage is discarded: the beat is consumed, no memory
// write happens, fbiPixelsOut does not increment.
//
// Zero-pixel-triangle convention with raster.sv: pixels outside the latched
// clip rect (only the dummy completion beat can be one — the raster clips all
// real spans to the rect) are discarded before stage 1; tri_done still pulses
// when such a beat carries px_last.
module pixel_pipe
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // triangle launch (observed; the pipe latches its own tri_params copy)
    input  logic        tri_valid,
    input  logic        tri_ready,
    input  tri_params_t tri_params,

    // pixel stream from raster (§7.2)
    input  logic        px_valid,
    output logic        px_ready,
    input  logic        px_last,
    input  logic [9:0]  px_x,
    input  logic [9:0]  px_y,
    input  logic signed [31:0] px_r,
    input  logic signed [31:0] px_g,
    input  logic signed [31:0] px_b,
    input  logic signed [31:0] px_a,
    input  logic signed [31:0] px_z,
    input  logic signed [63:0] px_w,
    input  logic signed [63:0] px_s0,
    input  logic signed [63:0] px_t0,
    input  logic signed [63:0] px_w0,

    output logic        tri_done,

    // fb_arb client port 2 (§7.3)
    output logic              req_valid,
    input  logic              req_ready,
    output logic              req_we,
    output logic [FB_AW-1:0]  req_addr,
    output logic [15:0]       req_wdata,
    input  logic              rsp_valid,
    input  logic [15:0]       rsp_rdata,

    output logic        pixout_inc
);

  // ----------------------------------------------------------------
  // helper functions (each mirrors a gold/MAME formula; see cites)
  // ----------------------------------------------------------------

  function automatic int iclampf(input int v, input int lo, input int hi);
    return (v < lo) ? lo : ((v > hi) ? hi : v);
  endfunction

  // count leading zeros of a nonzero 64-bit value
  function automatic logic [5:0] clz64f(input logic [63:0] v);
    logic [6:0] n;
    logic       found;
    n = 7'd0;
    found = 1'b0;
    for (int i = 63; i >= 0; i--) begin
      if (!found) begin
        if (v[i])
          found = 1'b1;
        else
          n = n + 7'd1;
      end
    end
    return n[5:0];
  endfunction

  // wfloat of the 16.32 W iterator <<16 — gold wfloat_of (voodoo_gold.c),
  // MAME compute_wfloat (mame_voodoo_render.cpp:66-74). Takes the low 48
  // bits of the iterator: the <<16 of the 16.48 form discards the top 16.
  function automatic logic [15:0] wfloatf(input logic [47:0] w48);
    logic [63:0]       iw;
    logic [5:0]        clz;
    logic signed [7:0] expv;
    logic [12:0]       mant;
    iw = {w48, 16'b0};                   // shl64(iterw32,16) wraps mod 2^64
    if (iw == 64'd0)
      return 16'h0000;
    clz  = clz64f(iw);
    expv = $signed({2'b00, clz}) - 8'sd16;
    if (expv < 8'sd0)
      return 16'h0000;
    if (expv >= 8'sd16)
      return 16'hffff;
    mant = 13'(iw >> (6'd35 - 6'(expv))) ^ 13'h1fff;
    // ((exp<<12) | mant) + 1, & 0xffff (gold) — 16-bit wrap is the same
    return ({expv[3:0], 12'b0} | {3'b000, mant}) + 16'd1;
  endfunction

  // gold clamped_z / MAME clamped_z (mame_voodoo_render.cpp:117-132)
  function automatic logic [15:0] clamped_zf(input logic signed [31:0] z,
                                             input logic clampbit);
    logic signed [31:0] v;
    logic [19:0]        r;
    if (clampbit) begin
      v = z >>> 12;
      return 16'(iclampf(int'(v), 0, 'hffff));
    end
    r = z[31:12];                        // logical u32 >> 12
    if (r == 20'hfffff) return 16'h0000;
    if (r == 20'h10000) return 16'hffff;
    return r[15:0];
  endfunction

  // gold clamp_argb_chan / MAME clamped_argb (mame_voodoo_render.cpp:84-109):
  // field = (u32(iter) >> 12) & 0xfff — the caller passes iter[23:12]
  function automatic logic [7:0] clamp_argbf(input logic [11:0] field,
                                             input logic clampbit);
    if (clampbit)
      return (field > 12'd255) ? 8'hff : field[7:0];
    if (field == 12'hfff) return 8'h00;
    if (field == 12'h100) return 8'hff;
    return field[7:0];
  endfunction

  // gold clamped_w (16.32 iterator; MAME operates on the <<16 16.48 form,
  // mame_voodoo_render.cpp:139-154) — used for cca_localselect == 3; the
  // caller passes iterw[47:32] (the only bits the formula consumes)
  function automatic logic [7:0] clamped_wf(input logic [15:0] r,
                                            input logic clampbit);
    if (clampbit) begin
      if (r[15])         return 8'h00;   // sext16 < 0 -> clamp to 0
      if (r > 16'h00ff)  return 8'hff;
      return r[7:0];
    end
    if (r == 16'hffff) return 8'h00;
    if (r == 16'h0100) return 8'hff;
    return r[7:0];
  endfunction

  // FBI color combine — gold combine_color_full, a verbatim port of MAME
  // combine_color (mame_voodoo_render.cpp:1511-1729). Returns {a,r,g,b}.
  // texel is the constant-white M2 stand-in; czh = clamped_z >> 8,
  // cw = clamped_w (gold combine_color_full cca_localselect cases 2/3).
  // Chroma-key and alpha-mask tests slot in after c_other selection (M4).
  function automatic logic [31:0] combine_colorf(
      input logic [25:0] cp,             // fbzColorPath[25:0] (all bits used)
      input logic [31:0] c0v,
      input logic [31:0] c1v,
      input logic [7:0]  itr, input logic [7:0] itg,
      input logic [7:0]  itb, input logic [7:0] ita,
      input logic [7:0]  txr, input logic [7:0] txg,
      input logic [7:0]  txb, input logic [7:0] txa,
      input logic [7:0]  czh, input logic [7:0] cw);
    int cor, cog, cob, coa;       // c_other
    int clr, clg, clb, cla;       // c_local
    int br, bg, bb, ba;
    int fr, fg, fb, fa;
    int ar, ag, ab, aa;
    int rr, rg, rb, ra;

    // c_other RGB: cc_rgbselect (cp[1:0])
    unique case (cp[1:0])
      2'd0:    begin cor = int'(itr);      cog = int'(itg);      cob = int'(itb);     end
      2'd1:    begin cor = int'(txr);      cog = int'(txg);      cob = int'(txb);     end
      2'd2:    begin cor = int'(c1v[23:16]); cog = int'(c1v[15:8]); cob = int'(c1v[7:0]); end
      default: begin cor = 0;              cog = 0;              cob = 0;             end
    endcase
    // (M4: chroma key test goes here)
    // c_other A: cc_aselect (cp[3:2])
    unique case (cp[3:2])
      2'd0:    coa = int'(ita);
      2'd1:    coa = int'(txa);
      2'd2:    coa = int'(c1v[31:24]);
      default: coa = 0;
    endcase
    // (M4: alpha mask test goes here)

    // c_local RGB: cc_localselect (cp[4]) / cc_localselect_override (cp[7])
    if (!cp[7]) begin
      if (!cp[4]) begin clr = int'(itr); clg = int'(itg); clb = int'(itb); end
      else begin
        clr = int'(c0v[23:16]); clg = int'(c0v[15:8]); clb = int'(c0v[7:0]);
      end
    end else begin
      if (!txa[7]) begin clr = int'(itr); clg = int'(itg); clb = int'(itb); end
      else begin
        clr = int'(c0v[23:16]); clg = int'(c0v[15:8]); clb = int'(c0v[7:0]);
      end
    end
    // a_local: cca_localselect (cp[6:5])
    unique case (cp[6:5])
      2'd0:    cla = int'(ita);
      2'd1:    cla = int'(c0v[31:24]);
      2'd2:    cla = int'(czh);            // u8(clamped_z >> 8)
      default: cla = int'(cw);             // u8(clamped_w)
    endcase

    // zero-other / subtract-local (cp[8], cp[17], cp[9], cp[18])
    br = cp[8]  ? 0 : cor;
    bg = cp[8]  ? 0 : cog;
    bb = cp[8]  ? 0 : cob;
    ba = cp[17] ? 0 : coa;
    if (cp[9]) begin br = br - clr; bg = bg - clg; bb = bb - clb; end
    if (cp[18]) ba = ba - cla;

    // blend factors: cc_mselect (cp[12:10]) / cca_mselect (cp[21:19])
    unique case (cp[12:10])
      3'd1:    begin fr = clr; fg = clg; fb = clb; end
      3'd2:    begin fr = coa; fg = coa; fb = coa; end
      3'd3:    begin fr = cla; fg = cla; fb = cla; end
      3'd4:    begin fr = int'(txa); fg = int'(txa); fb = int'(txa); end
      3'd5:    begin fr = int'(txr); fg = int'(txg); fb = int'(txb); end  // V2
      default: begin fr = 0; fg = 0; fb = 0; end
    endcase
    unique case (cp[21:19])
      3'd1, 3'd3: fa = cla;
      3'd2:       fa = coa;
      3'd4:       fa = int'(txa);
      default:    fa = 0;
    endcase
    // reverse_blend XOR (cp[13] / cp[22])
    if (!cp[13]) begin fr = fr ^ 'hff; fg = fg ^ 'hff; fb = fb ^ 'hff; end
    if (!cp[22]) fa = fa ^ 'hff;

    // add clocal/aclocal: cc_add_aclocal (cp[15:14]) / cca_add (cp[24:23])
    unique case (cp[15:14])
      2'd1:    begin ar = clr; ag = clg; ab = clb; end
      2'd2:    begin ar = cla; ag = cla; ab = cla; end
      default: begin ar = 0;   ag = 0;   ab = 0;   end   // 0 and 3 (reserved)
    endcase
    aa = (cp[24:23] != 2'd0) ? cla : 0;

    // (factor+1) multiply, >>8, add, clamp 0..255
    fr = fr + 1; fg = fg + 1; fb = fb + 1; fa = fa + 1;
    rr = iclampf(((br * fr) >>> 8) + ar, 0, 255);
    rg = iclampf(((bg * fg) >>> 8) + ag, 0, 255);
    rb = iclampf(((bb * fb) >>> 8) + ab, 0, 255);
    ra = iclampf(((ba * fa) >>> 8) + aa, 0, 255);

    // output inverts (cp[25] alpha, cp[16] rgb)
    if (cp[25]) ra = ra ^ 'hff;
    if (cp[16]) begin rr = rr ^ 'hff; rg = rg ^ 'hff; rb = rb ^ 'hff; end
    return {ra[7:0], rr[7:0], rg[7:0], rb[7:0]};
  endfunction

  // one alpha-blend factor — gold blend_rgb_scale / MAME alpha_blend factor
  // table (mame_voodoo_render.cpp:2009-2117): `other` is the DEST channel for
  // the source factor and the SOURCE channel for the dest factor; f15 is
  // min(sa, 0x100-da) (ASATURATE) on the source side and the color-before-fog
  // channel (A_COLORBEFOREFOG) on the dest side.
  function automatic int blend_scalef(input logic [3:0] mode, input int sa,
                                      input int da, input int other,
                                      input int f15);
    unique case (mode)
      4'd0:    return 0;                  // AZERO
      4'd1:    return sa + 1;             // ASRC_ALPHA
      4'd2:    return other + 1;          // A_COLOR
      4'd3:    return da + 1;             // ADST_ALPHA
      4'd4:    return 256;                // AONE
      4'd5:    return 'h100 - sa;         // AOMSRC_ALPHA
      4'd6:    return 'h100 - other;      // AOM_COLOR
      4'd7:    return 'h100 - da;         // AOMDST_ALPHA
      4'd15:   return f15 + 1;            // ASATURATE / A_COLORBEFOREFOG
      default: return 0;                  // reserved
    endcase
  endfunction

  // full blend — gold alpha_blend_full (dst alpha = 255 in M2; fog is M4 so
  // the color-before-fog equals the combine output `src` itself).
  // amf = alphaMode[23:8] (srcrgb/dstrgb/srcalpha/dstalpha factor codes).
  function automatic logic [31:0] alpha_blendf(input logic [15:0] amf,
                                               input logic [31:0] src,
                                               input logic [15:0] dstpix);
    logic [23:0] dexp;
    int dr, dg, db, da, sa, sr, sg, sb;
    int sat, ssr, ssg, ssb, dsr, dsg, dsb, sas, das;
    logic [7:0] rr, rg, rb, ra;
    dexp = unpack565(dstpix);
    dr = int'(dexp[23:16]); dg = int'(dexp[15:8]); db = int'(dexp[7:0]);
    da = 255;
    sa = int'(src[31:24]);
    sr = int'(src[23:16]); sg = int'(src[15:8]); sb = int'(src[7:0]);
    // ASATURATE operand: min(sa, 0x100 - da)
    sat = 'h100 - da;
    if (sa < sat) sat = sa;
    ssr = blend_scalef(amf[3:0],   sa, da, dr, sat);
    ssg = blend_scalef(amf[3:0],   sa, da, dg, sat);
    ssb = blend_scalef(amf[3:0],   sa, da, db, sat);
    dsr = blend_scalef(amf[7:4],   sa, da, sr, sr);  // prefog == src (fog M4)
    dsg = blend_scalef(amf[7:4],   sa, da, sg, sg);
    dsb = blend_scalef(amf[7:4],   sa, da, sb, sb);
    sas = (amf[11:8]  == 4'd4) ? 256 : 0;
    das = (amf[15:12] == 4'd4) ? 256 : 0;
    rr = 8'(iclampf((sr * ssr + dr * dsr) >>> 8, 0, 255));
    rg = 8'(iclampf((sg * ssg + dg * dsg) >>> 8, 0, 255));
    rb = 8'(iclampf((sb * ssb + db * dsb) >>> 8, 0, 255));
    ra = 8'(iclampf((sa * sas + da * das) >>> 8, 0, 255));
    return {ra, rr, rg, rb};
  endfunction

  // ----------------------------------------------------------------
  // latched triangle parameters
  // ----------------------------------------------------------------
  tri_params_t tp_q;

  // ----------------------------------------------------------------
  // FSM + per-pixel state
  // ----------------------------------------------------------------
  typedef enum logic [3:0] {
    P_IDLE,      // accept a pixel beat
    P_PREP,      // sy / addresses / OOB / wfloat / depthval / clamped iters
    P_ZREQ,      // issue depth read
    P_ZWAIT,     // wait stored depth, compare
    P_COMBINE,   // color combine
    P_ATEST,     // alpha test + blend routing
    P_BREQ,      // issue dest read for blend
    P_BWAIT,     // wait dest pixel
    P_BLEND,     // alpha blend
    P_WCOLOR,    // color write (if enabled and in range)
    P_WAUX,      // aux (depth/alpha) write (if enabled and in range)
    P_RETIRE     // consume beat; tri_done on px_last
  } pstate_e;

  pstate_e state_q;

  // latched pixel beat
  logic               last_q;
  logic [9:0]         x_q, y_q;
  logic signed [31:0] r_q, g_q, b_q, a_q, z_q;
  logic signed [63:0] w_q;

  // stage-1/2/3/4 results
  logic [1:0]         sy_lo_q;          // post-flip sy[1:0] (dither row)
  logic               dest_ok_q, aux_ok_q;
  logic [FB_AW-1:0]   dest_addr_q, aux_addr_q;
  logic [15:0]        depthval_q, depthsrc_q;
  logic [7:0]         ir_q, ig_q, ib_q, ia_q;
  logic [7:0]         czh_q, cw_q;
  logic [31:0]        col_q;            // {a,r,g,b}
  logic [15:0]        dpix_q;

  // ----------------------------------------------------------------
  // P_PREP combinational stage
  // ----------------------------------------------------------------
  logic signed [11:0] prep_sy;
  logic               prep_sy_ok, prep_off;
  logic [21:0]        prep_idx;
  logic [22:0]        prep_dword, prep_aword;
  logic               prep_dest_ok, prep_aux_ok;
  logic [15:0]        prep_wfloat, prep_cz;
  logic signed [17:0] prep_dv;
  logic [15:0]        prep_depthval;

  always_comb begin
    // 1) y-origin flip (fbzMode[17]; CONTRACTS §9.5 effective yorigin)
    prep_sy = tp_q.fbzmode[17]
            ? ($signed({2'b00, tp_q.yorigin}) - $signed({2'b00, y_q}))
            : $signed({2'b00, y_q});
    // CONTRACTS §9.6 guard, gold fb_word_ok: sy in [0,1023] and word in range
    prep_sy_ok = (prep_sy >= 12'sd0) && (prep_sy <= 12'sd1023);
    prep_idx   = 22'(prep_sy[9:0]) * 22'(tp_q.rowpixels) + 22'(x_q);
    prep_dword = {2'b00, tp_q.dest_base} + {1'b0, prep_idx};
    prep_aword = {2'b00, tp_q.aux_base} + {1'b0, prep_idx};
    prep_dest_ok = prep_sy_ok && (prep_dword[22:21] == 2'b00);
    prep_aux_ok  = prep_sy_ok && (prep_aword[22:21] == 2'b00);

    // out-of-clip-rect beat = the raster's zero-pixel dummy: discard
    prep_off = (x_q < tp_q.clip_left) || (x_q >= tp_q.clip_right) ||
               (y_q < tp_q.clip_top)  || (y_q >= tp_q.clip_bottom);

    // 2) wfloat, 3) depth value (gold pixel_pipe steps 1-2)
    prep_wfloat = wfloatf(w_q[47:0]);
    prep_cz     = clamped_zf(z_q, tp_q.fbzcp[28]);
    prep_dv     = tp_q.fbzmode[3] ? $signed({2'b00, prep_wfloat})
                                  : $signed({2'b00, prep_cz});
    if (tp_q.fbzmode[16]) begin
      // depth bias: += sext16(zaColor[15:0]), clamp [0,0xffff]
      prep_dv = prep_dv
              + $signed({{2{tp_q.zacolor[15]}}, tp_q.zacolor[15:0]});
      if (prep_dv < 18'sd0)
        prep_dv = 18'sd0;
      else if (prep_dv > 18'sd65535)
        prep_dv = 18'sd65535;
    end
    prep_depthval = prep_dv[15:0];
  end

  // ----------------------------------------------------------------
  // write-stage enables (gold pixel_pipe step 6)
  // ----------------------------------------------------------------
  logic do_wcolor, do_waux;
  assign do_wcolor = tp_q.fbzmode[9] & dest_ok_q;
  assign do_waux   = tp_q.fbzmode[10] & tp_q.aux_valid & aux_ok_q;

  // ----------------------------------------------------------------
  // fb port drive (no combinational req_valid -> req_ready loop: fb_arb's
  // c2_req_ready depends only on the other clients)
  // ----------------------------------------------------------------
  always_comb begin
    req_valid = 1'b0;
    req_we    = 1'b0;
    req_addr  = '0;
    req_wdata = '0;
    unique case (state_q)
      P_ZREQ: begin
        req_valid = 1'b1;
        req_addr  = aux_addr_q;
      end
      P_BREQ: begin
        req_valid = 1'b1;
        req_addr  = dest_addr_q;
      end
      P_WCOLOR: begin
        req_valid = do_wcolor;
        req_we    = 1'b1;
        req_addr  = dest_addr_q;
        // dither coords: pixel x, post-flip sy (gold dither565(fbz, x, sy, ..))
        req_wdata = dither565(col_q[23:16], col_q[15:8], col_q[7:0],
                              tp_q.fbzmode[8], tp_q.fbzmode[11],
                              x_q[1:0], sy_lo_q);
      end
      P_WAUX: begin
        req_valid = do_waux;
        req_we    = 1'b1;
        req_addr  = aux_addr_q;
        // enable_alpha_planes (fbzMode[18]): post-blend alpha, else depthval
        req_wdata = tp_q.fbzmode[18] ? {8'h00, col_q[31:24]} : depthval_q;
      end
      default: ;
    endcase
  end

  assign px_ready = (state_q == P_IDLE);
  assign tri_done = (state_q == P_RETIRE) & last_q;

  // ----------------------------------------------------------------
  // main sequential process
  // ----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q     <= P_IDLE;
      tp_q        <= '0;
      last_q      <= 1'b0;
      x_q <= '0; y_q <= '0;
      r_q <= '0; g_q <= '0; b_q <= '0; a_q <= '0; z_q <= '0; w_q <= '0;
      sy_lo_q     <= '0;
      dest_ok_q   <= 1'b0;
      aux_ok_q    <= 1'b0;
      dest_addr_q <= '0;
      aux_addr_q  <= '0;
      depthval_q  <= '0;
      depthsrc_q  <= '0;
      ir_q <= '0; ig_q <= '0; ib_q <= '0; ia_q <= '0;
      czh_q       <= '0;
      cw_q        <= '0;
      col_q       <= '0;
      dpix_q      <= '0;
      pixout_inc  <= 1'b0;
    end else begin
      pixout_inc <= 1'b0;

      // pipe owns the tri_params latch (§7.2)
      if (tri_valid && tri_ready)
        tp_q <= tri_params;

      unique case (state_q)
        // ------------------------------------------------------------
        P_IDLE: begin
          if (px_valid) begin
            last_q <= px_last;
            x_q    <= px_x;
            y_q    <= px_y;
            r_q    <= px_r;
            g_q    <= px_g;
            b_q    <= px_b;
            a_q    <= px_a;
            z_q    <= px_z;
            w_q    <= px_w;
            state_q <= P_PREP;
          end
        end

        // ------------------------------------------------------------
        P_PREP: begin
          sy_lo_q     <= prep_sy[1:0];
          dest_ok_q   <= prep_dest_ok;
          aux_ok_q    <= prep_aux_ok;
          dest_addr_q <= prep_dword[FB_AW-1:0];
          aux_addr_q  <= prep_aword[FB_AW-1:0];
          depthval_q  <= prep_depthval;
          // depth_source_compare (fbzMode[20]): u16 zaColor
          depthsrc_q  <= tp_q.fbzmode[20] ? tp_q.zacolor[15:0] : prep_depthval;
          // 4) iterated ARGB clamp (gold clamp_argb_chan)
          ir_q <= clamp_argbf(r_q[23:12], tp_q.fbzcp[28]);
          ig_q <= clamp_argbf(g_q[23:12], tp_q.fbzcp[28]);
          ib_q <= clamp_argbf(b_q[23:12], tp_q.fbzcp[28]);
          ia_q <= clamp_argbf(a_q[23:12], tp_q.fbzcp[28]);
          czh_q <= prep_cz[15:8];
          cw_q  <= clamped_wf(w_q[47:32], tp_q.fbzcp[28]);
          if (prep_off)
            state_q <= P_RETIRE;          // raster's zero-pixel dummy beat
          else if (tp_q.fbzmode[4] && tp_q.aux_valid && prep_aux_ok)
            state_q <= P_ZREQ;            // depth test (gold pixel_pipe)
          else
            state_q <= P_COMBINE;         // test skipped: aux unusable/OOB
        end

        // ------------------------------------------------------------
        P_ZREQ:  if (req_ready) state_q <= P_ZWAIT;

        P_ZWAIT: begin
          if (rsp_valid) begin
            // depth func fbzMode[7:5] vs stored aux word
            if (cmp_pass(tp_q.fbzmode[7:5],
                         {1'b0, depthsrc_q}, {1'b0, rsp_rdata}))
              state_q <= P_COMBINE;
            else
              state_q <= P_RETIRE;        // z-fail discard
          end
        end

        // ------------------------------------------------------------
        P_COMBINE: begin
          // 5) color combine; texel = ARGB(255,255,255,255) in M2
          col_q <= combine_colorf(tp_q.fbzcp[25:0], tp_q.color0, tp_q.color1,
                                  ir_q, ig_q, ib_q, ia_q,
                                  8'd255, 8'd255, 8'd255, 8'd255,
                                  czh_q, cw_q);
          // (M4: chroma key / alpha mask / stipple / fog slot in after this)
          state_q <= P_ATEST;
        end

        P_ATEST: begin
          // 6) alpha test (alphaMode[0]; func [3:1]; ref [31:24])
          if (tp_q.alphamode[0] &&
              !cmp_pass(tp_q.alphamode[3:1],
                        {9'b0, col_q[31:24]}, {9'b0, tp_q.alphamode[31:24]}))
            state_q <= P_RETIRE;          // alpha-fail discard
          else if (tp_q.alphamode[4]) begin
            // 7) alpha blend: dest pixel reads as 0 when OOB (gold)
            if (dest_ok_q)
              state_q <= P_BREQ;
            else begin
              dpix_q  <= 16'h0000;
              state_q <= P_BLEND;
            end
          end else begin
            pixout_inc <= 1'b1;
            state_q    <= P_WCOLOR;
          end
        end

        P_BREQ:  if (req_ready) state_q <= P_BWAIT;

        P_BWAIT: begin
          if (rsp_valid) begin
            dpix_q  <= rsp_rdata;
            state_q <= P_BLEND;
          end
        end

        P_BLEND: begin
          col_q      <= alpha_blendf(tp_q.alphamode[23:8], col_q, dpix_q);
          pixout_inc <= 1'b1;             // pixel reaches the write stage
          state_q    <= P_WCOLOR;
        end

        // ------------------------------------------------------------
        // 8) writes (gold pixel_pipe step 6: color first, then aux;
        //    fbiPixelsOut already counted on entry to the write stage)
        P_WCOLOR: if (!do_wcolor || req_ready) state_q <= P_WAUX;
        P_WAUX:   if (!do_waux || req_ready)   state_q <= P_RETIRE;

        P_RETIRE: state_q <= P_IDLE;      // tri_done pulses here on px_last

        default: state_q <= P_IDLE;
      endcase
    end
  end

  // M3 iterators, tri_params fields and register bits not consumed by the
  // M2 pipe (fbzMode/fbzColorPath/alphaMode bits outside the M2 feature set;
  // px_r/g/b/a only contribute their 12-bit clamp fields per MAME)
  logic unused_sink;
  assign unused_sink = &{1'b0, px_s0, px_t0, px_w0,
                         tp_q.ax, tp_q.ay, tp_q.bx, tp_q.by, tp_q.cx, tp_q.cy,
                         tp_q.sign,
                         tp_q.startr, tp_q.startg, tp_q.startb, tp_q.starta,
                         tp_q.drdx, tp_q.dgdx, tp_q.dbdx, tp_q.dadx,
                         tp_q.drdy, tp_q.dgdy, tp_q.dbdy, tp_q.dady,
                         tp_q.startz, tp_q.dzdx, tp_q.dzdy,
                         tp_q.startw, tp_q.dwdx, tp_q.dwdy,
                         tp_q.s0, tp_q.ds0dx, tp_q.ds0dy,
                         tp_q.t0, tp_q.dt0dx, tp_q.dt0dy,
                         tp_q.w0, tp_q.dw0dx, tp_q.dw0dy,
                         tp_q.fogmode, tp_q.texmode, tp_q.tlod,
                         tp_q.fbzmode[31:21], tp_q.fbzmode[19],
                         tp_q.fbzmode[15:12], tp_q.fbzmode[2:0],
                         tp_q.fbzcp[31:29], tp_q.fbzcp[27:26],
                         tp_q.alphamode[7:5],
                         tp_q.zacolor[31:16],
                         r_q[31:24], r_q[11:0], g_q[31:24], g_q[11:0],
                         b_q[31:24], b_q[11:0], a_q[31:24], a_q[11:0],
                         z_q[11:0], w_q[63:48], w_q[31:0]};

endmodule
