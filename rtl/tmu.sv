// tmu.sv — M3 Texture Mapping Unit (CONTRACTS §11b). Bit-exact mirror of the
// FROZEN gold model model/voodoo_gold.c texture path: tex_recompute,
// compute_lodbase, fast_log2_i64/u128, fetch_texel, lookup_texel,
// texel_expand, and the texture-combine (combine_generic with other=0,
// local=raw, texelA=raw.a, lodfrac=0). Integer-only, sequential.
//
// Per-triangle: latch tri_params at tri_valid&&tri_ready, run tex_recompute
// (sequential lodoffset accumulation, same chain as tex_dl) and compute_lodbase
// (128-bit sum-of-squares of the s64 S/T gradients).
// Per-pixel: smp_valid request -> perspective/affine coordinate, LOD select,
// point/bilinear address gen, 1 or 4 sequential tex_ram reads, expand, blend,
// texture-combine -> tex_valid {a,r,g,b}.
module tmu
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // triangle launch (observed; the TMU latches its own tri_params copy)
    input  logic        tri_valid,
    input  logic        tri_ready,
    input  tri_params_t tri_params,
    input  logic [31:0] texbaseaddr,   // live REG_texBaseAddr (latched at launch)
    output logic        tmu_ready,     // 1 when able to accept a new launch

    // per-pixel sample request from pixel_pipe (§11b)
    input  logic        smp_valid,
    output logic        smp_ready,
    input  logic [63:0] smp_s0,
    input  logic [63:0] smp_t0,
    input  logic [63:0] smp_w0,

    // post-combine texel response
    output logic        tex_valid,
    input  logic        tex_ready,
    output logic [7:0]  tex_a,
    output logic [7:0]  tex_r,
    output logic [7:0]  tex_g,
    output logic [7:0]  tex_b,

    // tex_ram read port
    output logic [TEX_AW-1:0] trd_addr,
    input  logic [15:0]       trd_data
);

  // ================================================================
  //  helpers
  // ================================================================
  function automatic int iclampf(input int v, input int lo, input int hi);
    return (v < lo) ? lo : ((v > hi) ? hi : v);
  endfunction

  function automatic logic [7:0] expbits1(input logic b);
    return b ? 8'hff : 8'h00;
  endfunction

`ifndef VOODOO_INT
  // ---- FLOAT path (INT=0, gold-exact) ---------------------------------------
  // log2tab + fast_log2f are the MAME-derived FLOAT baseline (s_log2_table bit
  // pattern; behavioral `real`). Under VOODOO_INT the integer log2 lives in the
  // shared voodoo_pkg::vd_log2_int (CLZ + vd_log2_mant LUT, PLAN §3.0/§3.2-A);
  // callers switch which they invoke (S_LODBASE / S_DIV below). No `else body
  // is needed here.
  // s_log2_table (MAME) — 7-bit mantissa index -> 8-bit frac
  function automatic logic [7:0] log2tab(input logic [6:0] m);
    logic [7:0] t [128];
    t = '{
      8'd0,  8'd2,  8'd5,  8'd8,  8'd11, 8'd14, 8'd16, 8'd19,
      8'd22, 8'd25, 8'd27, 8'd30, 8'd33, 8'd35, 8'd38, 8'd40,
      8'd43, 8'd46, 8'd48, 8'd51, 8'd53, 8'd56, 8'd58, 8'd61,
      8'd63, 8'd65, 8'd68, 8'd70, 8'd73, 8'd75, 8'd77, 8'd80,
      8'd82, 8'd84, 8'd87, 8'd89, 8'd91, 8'd93, 8'd96, 8'd98,
      8'd100,8'd102,8'd104,8'd106,8'd109,8'd111,8'd113,8'd115,
      8'd117,8'd119,8'd121,8'd123,8'd125,8'd127,8'd129,8'd132,
      8'd134,8'd136,8'd138,8'd140,8'd141,8'd143,8'd145,8'd147,
      8'd149,8'd151,8'd153,8'd155,8'd157,8'd159,8'd161,8'd162,
      8'd164,8'd166,8'd168,8'd170,8'd172,8'd173,8'd175,8'd177,
      8'd179,8'd181,8'd182,8'd184,8'd186,8'd188,8'd189,8'd191,
      8'd193,8'd194,8'd196,8'd198,8'd200,8'd201,8'd203,8'd205,
      8'd206,8'd208,8'd209,8'd211,8'd213,8'd214,8'd216,8'd218,
      8'd219,8'd221,8'd222,8'd224,8'd225,8'd227,8'd229,8'd230,
      8'd232,8'd233,8'd235,8'd236,8'd238,8'd239,8'd241,8'd242,
      8'd244,8'd245,8'd247,8'd248,8'd250,8'd251,8'd253,8'd254
    };
    return t[m];
  endfunction

  // fast_log2(real value, int fracbits) — bit-exact mirror of gold fast_log2:
  //   union{double;u64} -> ival = bits>>45; exp = (ival>>7)-1023-fracbits;
  //   return (exp<<8) | s_log2_table[ival&127]; value<0 -> 0.
  // Uses $realtobits for the IEEE-754 double bit pattern (== C union punning).
  // `real` is sim-only (behavioral); accepted trade for bit-exact float match.
  function automatic logic signed [31:0] fast_log2f(input real value,
                                                    input int fracbits);
    // JUSTIFICATION: only the top 19 bits of the IEEE-754 double pattern matter
    // (sign+exponent+top-7 mantissa, gold's bits>>45); the low 45 mantissa bits
    // are intentionally discarded, exactly like gold's (uint32_t)(temp.i>>45).
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0]        bits64;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [18:0]        ival;     // (u64 bits) >> 45
    logic signed [23:0] expv;
    if (value < 0.0)
      return 32'sd0;
    bits64 = $realtobits(value);
    ival = bits64[63:45];
    // exp = (ival >> 7) - 1023 - fracbits  (ival>>7 is the 12-bit {sign,exp});
    // truncated to 24 bits, matching gold's (uint32_t)exp << 8 | table low bits
    expv = 24'($signed({20'd0, ival[18:7]}) - 32'sd1023 - 32'(fracbits));
    return $signed({expv, 8'd0} | {24'd0, log2tab(ival[6:0])});
  endfunction
`endif // !VOODOO_INT  (FLOAT log2 path)

  // ================================================================
  //  latched triangle params
  // ================================================================
  tri_params_t tp_q;
  logic [18:0] texbase_lo_q;   // texBaseAddr & 0x7ffff, latched at launch

  // tex_recompute combinational fields (from latched tlod/texmode)
  logic [3:0]  fmt;
  logic        bpt2;
  logic        bppscale;
  logic [8:0]  lodmask;
  logic [7:0]  wmask, hmask;
  logic signed [31:0] lodmin, lodmax, lodbias;

  always_comb begin
    fmt      = tp_q.texmode[11:8];
    bpt2     = fmt[3];
    bppscale = fmt[3];
    lodmin   = $signed(32'(tp_q.tlod[5:0]) <<< 6);
    lodmax   = $signed(32'(tp_q.tlod[11:6]) <<< 6);
    lodbias  = $signed({{24{tp_q.tlod[17]}}, tp_q.tlod[17:12], 2'b00}) <<< 4;
    lodmask  = tp_q.tlod[19] ? (tp_q.tlod[18] ? 9'h0aa : 9'h155) : 9'h1ff;
    if (tp_q.tlod[20]) begin
      wmask = 8'hff;
      hmask = 8'hff >> tp_q.tlod[22:21];
    end else begin
      wmask = 8'hff >> tp_q.tlod[22:21];
      hmask = 8'hff;
    end
  end

  logic [20:0] lodoff_q [9];

  // lodoffset accumulation working state
  logic [25:0] acc_q;
  logic [3:0]  li_q;
  logic [8:0]  wsz, hsz;
  logic [17:0] fp;
  logic [18:0] fp_sc;
  always_comb begin
    logic [2:0] k;
    k   = li_q[2:0] - 3'd1;
    wsz = {1'b0, wmask >> k} + 9'd1;
    hsz = {1'b0, hmask >> k} + 9'd1;
    fp  = 18'(wsz) * 18'(hsz);
    if ((li_q >= 4'd4) && (fp < 18'd4))
      fp = 18'd4;
    fp_sc = bppscale ? {fp, 1'b0} : {1'b0, fp};
  end

  logic signed [31:0] lodbase_q;

  // ================================================================
  //  per-pixel state
  // ================================================================
  logic signed [63:0] s0_q, t0_q, w0_q;
  logic signed [31:0] coord_s_q, coord_t_q;
  logic signed [31:0] lod_persp_q;
  logic               negw_q;

  logic [3:0]  ilod_q;
  logic [20:0] texbase_q;
  logic [7:0]  smax_q, tmax_q;
  logic        point_q;
  logic [7:0]  sfrac_q, tfrac_q;
  logic [7:0]  cs_ss, cs_s1, cs_tt, cs_t1;
  logic [1:0]  corner_q;
  logic        cs_unused;   // lint sink for s1/t1 upper bits (see S_LODCALC)

  logic [7:0] e_a [4], e_r [4], e_g [4], e_b [4];
  logic [15:0] raw_w;

  // ----------------------------------------------------------------
  // texel_expand (combinational from raw_w + latched fmt)
  // ----------------------------------------------------------------
  logic [7:0] ex_a, ex_r, ex_g, ex_b;
  always_comb begin
    ex_a = 8'hff; ex_r = 8'h00; ex_g = 8'h00; ex_b = 8'h00;
    unique case (fmt)
      4'd0, 4'd8: begin       // RGB 3-3-2: r=(r<<5)|(r<<2)|(r>>1) etc.
        ex_r = {raw_w[7:5], raw_w[7:5], raw_w[7:6]};
        ex_g = {raw_w[4:2], raw_w[4:2], raw_w[4:3]};
        ex_b = {raw_w[1:0], raw_w[1:0], raw_w[1:0], raw_w[1:0]};
        ex_a = 8'hff;
      end
      4'd2: begin             // A8 -> AAAA
        ex_a = raw_w[7:0]; ex_r = raw_w[7:0]; ex_g = raw_w[7:0]; ex_b = raw_w[7:0];
      end
      4'd3, 4'd13: begin      // I8 intensity
        ex_a = 8'hff; ex_r = raw_w[7:0]; ex_g = raw_w[7:0]; ex_b = raw_w[7:0];
      end
      4'd1, 4'd5, 4'd7: begin // grayscale pal565[v] = to565(v,v,v), from565
        ex_r = {raw_w[7:3], raw_w[7:5]};
        ex_g = {raw_w[7:2], raw_w[7:6]};
        ex_b = {raw_w[7:3], raw_w[7:5]};
        ex_a = 8'hff;
      end
      4'd4: begin             // AI44
        ex_a = {raw_w[7:4], raw_w[7:4]};
        ex_r = {raw_w[3:0], raw_w[3:0]};
        ex_g = {raw_w[3:0], raw_w[3:0]};
        ex_b = {raw_w[3:0], raw_w[3:0]};
      end
      4'd10: begin            // RGB565
        ex_r = {raw_w[15:11], raw_w[15:13]};
        ex_g = {raw_w[10:5],  raw_w[10:9]};
        ex_b = {raw_w[4:0],   raw_w[4:2]};
        ex_a = 8'hff;
      end
      4'd11: begin            // ARGB1555
        ex_a = expbits1(raw_w[15]);
        ex_r = {raw_w[14:10], raw_w[14:12]};
        ex_g = {raw_w[9:5],   raw_w[9:7]};
        ex_b = {raw_w[4:0],   raw_w[4:2]};
      end
      4'd12: begin            // ARGB4444
        ex_a = {raw_w[15:12], raw_w[15:12]};
        ex_r = {raw_w[11:8],  raw_w[11:8]};
        ex_g = {raw_w[7:4],   raw_w[7:4]};
        ex_b = {raw_w[3:0],   raw_w[3:0]};
      end
      default: begin          // magenta = unimplemented
        ex_a = 8'hff; ex_r = 8'hff; ex_g = 8'h00; ex_b = 8'hff;
      end
    endcase
  end

  // ----------------------------------------------------------------
  // texture-combine = combine_generic(ctex, other=0, local=raw, texelA=raw.a, 0)
  // ----------------------------------------------------------------
  function automatic logic [31:0] tex_combine(
      input logic [31:0] tm,
      input logic [7:0]  lr, input logic [7:0] lg,
      input logic [7:0]  lb, input logic [7:0] la);
    int br, bg, bb, ba;
    int fr, fg, fb, fa;
    int ar, ag, ab, aa;
    int orr, og, ob, oa;
    logic       c_sub, c_sub_a;
    logic [2:0] c_msel, c_msel_a;
    logic       c_rev, c_rev_a;
    logic [1:0] c_add, c_add_a;
    logic       c_inv, c_inv_a;
    // tm[12]/tm[21] (tc_zero/tca_zero) are no-ops here: other is already 0
    c_sub    = tm[13]; c_msel   = tm[16:14];
    c_rev    = tm[17]; c_add    = tm[19:18]; c_inv  = tm[20];
    c_sub_a  = tm[22]; c_msel_a = tm[25:23];
    c_rev_a  = tm[26]; c_add_a  = tm[28:27]; c_inv_a = tm[29];

    // other = 0; base = 0 (zero_other irrelevant since other already 0)
    br = 0; bg = 0; bb = 0; ba = 0;
    if (c_sub)   begin br = br - int'(lr); bg = bg - int'(lg); bb = bb - int'(lb); end
    if (c_sub_a) begin ba = ba - int'(la); end

    unique case (c_msel)
      3'd1:    begin fr = int'(lr); fg = int'(lg); fb = int'(lb); end
      3'd2:    begin fr = 0; fg = 0; fb = 0; end       // other.a == 0
      3'd3:    begin fr = int'(la); fg = int'(la); fb = int'(la); end
      3'd4:    begin fr = int'(la); fg = int'(la); fb = int'(la); end // texelA
      3'd5:    begin fr = 0; fg = 0; fb = 0; end       // lodfrac == 0
      default: begin fr = 0; fg = 0; fb = 0; end
    endcase
    unique case (c_msel_a)
      3'd1, 3'd3: fa = int'(la);
      3'd2:       fa = 0;
      3'd4:       fa = int'(la);
      3'd5:       fa = 0;
      default:    fa = 0;
    endcase
    if (!c_rev)   begin fr = fr ^ 'hff; fg = fg ^ 'hff; fb = fb ^ 'hff; end
    if (!c_rev_a) begin fa = fa ^ 'hff; end
    fr = fr + 1; fg = fg + 1; fb = fb + 1; fa = fa + 1;

    ar = 0; ag = 0; ab = 0; aa = 0;
    if (c_add == 2'd1)      begin ar = int'(lr); ag = int'(lg); ab = int'(lb); end
    else if (c_add == 2'd2) begin ar = int'(la); ag = int'(la); ab = int'(la); end
    if (c_add_a != 2'd0) aa = int'(la);

    orr = iclampf(((br * fr) >>> 8) + ar, 0, 255);
    og  = iclampf(((bg * fg) >>> 8) + ag, 0, 255);
    ob  = iclampf(((bb * fb) >>> 8) + ab, 0, 255);
    oa  = iclampf(((ba * fa) >>> 8) + aa, 0, 255);
    if (c_inv)   begin orr = orr ^ 'hff; og = og ^ 'hff; ob = ob ^ 'hff; end
    if (c_inv_a) begin oa = oa ^ 'hff; end
    // tm[12]/tm[21] (tc_zero/tca_zero) and the format/control bits outside the
    // combine range are no-ops here (other == 0); reference to silence lint.
    if (&{1'b0, tm[31:30], tm[21], tm[12:0]}) oa = oa;
    return {oa[7:0], orr[7:0], og[7:0], ob[7:0]};
  endfunction

  // ================================================================
  //  LOD-resolve combinational (from coord_*/lod_persp/lodbase)
  // ================================================================
  logic signed [31:0] lc_lod_clamped;
  logic [3:0]         lc_ilod;
  logic               lc_point;
  logic [7:0]         lc_smax, lc_tmax;
  always_comb begin
    logic signed [31:0] lod;
    logic [31:0]        ilod32;
    logic [31:0]        notmask;
    lod = lod_persp_q + lodbase_q + lodbias;
    if (lod < lodmin) lod = lodmin;
    if (lod > lodmax) lod = lodmax;
    lc_lod_clamped = lod;
    // ilod = lod >> 8 (arithmetic; lod >= lodmin >= 0)
    ilod32  = $unsigned(lod >>> 8);
    // ilod += (~lodmask >> ilod) & 1  (lodmask widened to 32 bits like gold int)
    notmask = ~{23'd0, lodmask};
    ilod32  = ilod32 + ((notmask >> ilod32[4:0]) & 32'd1);
    if (ilod32 > 32'd8) ilod32 = 32'd8;
    lc_ilod  = ilod32[3:0];
    lc_point = ((lc_lod_clamped == lodmin) && !tp_q.texmode[2]) ||
               ((lc_lod_clamped != lodmin) && !tp_q.texmode[1]);
  end
  assign lc_smax = wmask >> lc_ilod;
  assign lc_tmax = hmask >> lc_ilod;

  // ================================================================
  //  texel address for the current corner (combinational)
  // ================================================================
  logic [7:0]        cur_s, cur_t;
  logic [TEX_AW-1:0] word_addr;
  logic              byte_hi;
  always_comb begin
    logic [16:0] tprod, ts;
    logic [20:0] ba;   // byte address, wraps mod 2^21 == & TEX_MASK
    unique case (corner_q)
      2'd0: begin cur_s = cs_ss; cur_t = cs_tt; end
      2'd1: begin cur_s = cs_s1; cur_t = cs_tt; end
      2'd2: begin cur_s = cs_ss; cur_t = cs_t1; end
      default: begin cur_s = cs_s1; cur_t = cs_t1; end
    endcase
    tprod = 17'(cur_t) * (17'(smax_q) + 17'd1);
    ts    = tprod + 17'(cur_s);
    if (!bpt2) begin
      ba        = texbase_q + {4'b0, ts};        // (texbase + t + s) & TEX_MASK
      word_addr = ba[TEX_AW:1];                  // byte >> 1
      byte_hi   = ba[0];
    end else begin
      ba        = texbase_q + {3'b0, ts, 1'b0};  // (texbase + 2*(t+s)) & TEX_MASK
      word_addr = ba[TEX_AW:1];                  // & ~1 -> drop byte bit0
      byte_hi   = 1'b0;
    end
  end
  assign trd_addr = word_addr;

  // bilinear blend combinational
  logic [7:0] bl_a, bl_r, bl_g, bl_b;
  always_comb begin
    int isf, itf, w00, w10, w01, w11;
    isf = 256 - int'(sfrac_q);
    itf = 256 - int'(tfrac_q);
    w00 = (isf * itf) >>> 8;
    w10 = (int'(sfrac_q) * itf) >>> 8;
    w01 = (isf * int'(tfrac_q)) >>> 8;
    w11 = (int'(sfrac_q) * int'(tfrac_q)) >>> 8;
    bl_a = 8'((int'(e_a[0])*w00 + int'(e_a[1])*w10 + int'(e_a[2])*w01 + int'(e_a[3])*w11) >>> 8);
    bl_r = 8'((int'(e_r[0])*w00 + int'(e_r[1])*w10 + int'(e_r[2])*w01 + int'(e_r[3])*w11) >>> 8);
    bl_g = 8'((int'(e_g[0])*w00 + int'(e_g[1])*w10 + int'(e_g[2])*w01 + int'(e_g[3])*w11) >>> 8);
    bl_b = 8'((int'(e_b[0])*w00 + int'(e_b[1])*w10 + int'(e_b[2])*w01 + int'(e_b[3])*w11) >>> 8);
  end

  // ================================================================
  //  FSM
  // ================================================================
  typedef enum logic [3:0] {
    S_IDLE,      // ready for triangle launch
    S_LOD,       // lodoffset accumulation
    S_LODBASE,   // compute_lodbase, then ready
    S_RDY,       // accept sample requests (between pixels)
    S_DIV,       // perspective/affine coordinate
    S_DIVW,      // VOODOO_INT: wait for the SRT perspective divides
    S_LODCALC,   // resolve LOD + corner coords
    S_ADDR,      // drive trd_addr
    S_RDLAT,     // read latency cycle
    S_EXPAND,    // raw_w settled; ex_* valid -> capture corner
    S_NEXT,      // advance corner / finish
    S_BLEND,     // bilinear blend + combine (e_* settled)
    S_RESP       // present tex_valid
  } st_e;
  st_e state_q;

  logic [31:0] comb_q;

  assign smp_ready = (state_q == S_RDY);
  assign tmu_ready = (state_q == S_IDLE) || (state_q == S_RDY);
  assign tex_valid = (state_q == S_RESP);
  assign tex_a = comb_q[31:24];
  assign tex_r = comb_q[23:16];
  assign tex_g = comb_q[15:8];
  assign tex_b = comb_q[7:0];

  // texturing predicate of the incoming launch (gold: CP_texenable && tm!=0)
  logic launch_tex;
  assign launch_tex = tri_params.fbzcp[27] && (tri_params.texmode != 32'd0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q   <= S_IDLE;
      tp_q      <= '0;
      texbase_lo_q <= '0;
      acc_q     <= '0;
      li_q      <= '0;
      lodbase_q <= '0;
      lodoff_q  <= '{default:'0};
      s0_q <= '0; t0_q <= '0; w0_q <= '0;
      coord_s_q <= '0; coord_t_q <= '0; lod_persp_q <= '0; negw_q <= 1'b0;
      ilod_q <= '0; texbase_q <= '0; smax_q <= '0; tmax_q <= '0; point_q <= 1'b0;
      sfrac_q <= '0; tfrac_q <= '0;
      cs_ss <= '0; cs_s1 <= '0; cs_tt <= '0; cs_t1 <= '0;
      corner_q <= '0; comb_q <= '0; raw_w <= '0; cs_unused <= 1'b0;
      e_a <= '{default:'0}; e_r <= '{default:'0};
      e_g <= '{default:'0}; e_b <= '{default:'0};
    end else begin
      // triangle launch is accepted in S_IDLE or S_RDY (both = "not mid work")
      if (tri_valid && tri_ready &&
          ((state_q == S_IDLE) || (state_q == S_RDY))) begin
        tp_q         <= tri_params;
        texbase_lo_q <= texbaseaddr[18:0];
        if (launch_tex) begin
          acc_q   <= {4'b0, texbaseaddr[18:0], 3'b000};
          li_q    <= 4'd1;
          state_q <= S_LOD;
        end else begin
          state_q <= S_RDY;
        end
      end else begin
        unique case (state_q)
          S_IDLE: ; // wait for launch (handled above)

          S_LOD: begin
            if (li_q == 4'd1)
              lodoff_q[0] <= acc_q[20:0];
            if (li_q > 4'd8) begin
              state_q <= S_LODBASE;
            end else begin
              logic [25:0] nacc;
              nacc = lodmask[li_q - 4'd1] ? (acc_q + {7'b0, fp_sc}) : acc_q;
              lodoff_q[li_q] <= nacc[20:0];
              acc_q <= nacc;
              li_q  <= li_q + 4'd1;
            end
          end

          S_LODBASE: begin
`ifndef VOODOO_INT
            // ---- FLOAT path (INT=0, gold-exact) ----
            // compute_lodbase (gold): texdx = (double)dsdx^2 + (double)dtdx^2,
            // texdy similarly; return fast_log2(max(texdx,texdy), 64) / 2.
            // Same operand order/grouping as gold for bit-exact float match.
            real fdsdx, fdsdy, fdtdx, fdtdy, texdx, texdy, maxval;
            logic signed [31:0] l2;
            fdsdx = real'($signed(tp_q.ds0dx));
            fdsdy = real'($signed(tp_q.ds0dy));
            fdtdx = real'($signed(tp_q.dt0dx));
            fdtdy = real'($signed(tp_q.dt0dy));
            texdx = fdsdx * fdsdx + fdtdx * fdtdx;
            texdy = fdsdy * fdsdy + fdtdy * fdtdy;
            maxval = (texdx > texdy) ? texdx : texdy;
            l2 = fast_log2f(maxval, 64);
            lodbase_q <= l2 / 32'sd2;   // C int /2 truncates toward zero
            state_q <= S_RDY;
`else
            // ---- INTEGER path (VOODOO_INT, SPEC §6.1 / PLAN §3.2-B) ----
            // Exact 128-bit sum-of-squares of the s32 14.18 S/T gradients
            // (widen to s64 before squaring; product fits 128b), take the max,
            // then integer log2 (fracbits=64) >>> 1 = /2 of the sqrt. The /2 is
            // an arithmetic shift; log2(max) >= 0 here so >>> 1 == toward zero.
            logic signed [63:0] gx0, gy0, gx1, gy1;
            logic [127:0]       texdx, texdy, maxv;
            gx0 = 64'($signed(tp_q.ds0dx)); gy0 = 64'($signed(tp_q.dt0dx));
            gx1 = 64'($signed(tp_q.ds0dy)); gy1 = 64'($signed(tp_q.dt0dy));
            texdx = 128'($signed(gx0) * $signed(gx0))
                  + 128'($signed(gy0) * $signed(gy0));   // exact, ~128b
            texdy = 128'($signed(gx1) * $signed(gx1))
                  + 128'($signed(gy1) * $signed(gy1));
            maxv  = (texdx > texdy) ? texdx : texdy;
            lodbase_q <= vd_log2_int(maxv, 64) >>> 1;     // /2 toward zero (log2>=0)
            state_q   <= S_RDY;
`endif
          end

          S_RDY: begin
            if (smp_valid) begin
              s0_q <= $signed(smp_s0);
              t0_q <= $signed(smp_t0);
              w0_q <= $signed(smp_w0);
              state_q <= S_DIV;
            end
          end

          S_DIV: begin
`ifndef VOODOO_INT
            // ---- FLOAT path (INT=0, gold-exact) ----
            // FLOAT perspective/affine, bit-exact mirror of gold fetch_texel.
            // iters/itert/iterw = (double)(int64_t)iterator; iterw==0 -> 1.0
            // (substituted at the gold call site, so clampnegw sees it too).
            // `real` is sim-only (behavioral); accepted trade for float match.
            real iters, itert, iterw, recip;
            iters = real'($signed(s0_q));
            itert = real'($signed(t0_q));
            iterw = real'($signed(w0_q));
            if (iterw == 0.0) iterw = 1.0;
            if (tp_q.texmode[0]) begin
              recip       = 256.0 / iterw;
              coord_s_q   <= $rtoi(iters * recip);
              coord_t_q   <= $rtoi(itert * recip);
              lod_persp_q <= -fast_log2f(iterw, 32);
            end else begin
              coord_s_q   <= $rtoi(iters * (1.0 / real'(32'sd1 <<< 24)));
              coord_t_q   <= $rtoi(itert * (1.0 / real'(32'sd1 <<< 24)));
              lod_persp_q <= 32'sd0;
            end
            negw_q  <= (iterw < 0.0);
            state_q <= S_LODCALC;
`else
            // ---- INTEGER path (VOODOO_INT, SPEC §5.2 / §6.1 / PLAN §3.2-C) ----
            // iters/itert/iterw = (int64) iterators; iterw==0 -> 1 (same div-by-
            // zero guard as the float path, substituted before BOTH the
            // reciprocal and the log2 so clampnegw/lod see the guarded value).
            logic signed [63:0] iters, itert, iterw;
            iters = $signed(s0_q); itert = $signed(t0_q); iterw = $signed(w0_q);
            if (iterw == 64'sd0) iterw = 64'sd1;     // div-by-zero guard
            if (tp_q.texmode[0]) begin               // perspective
              // S = (S/W)/(1/W): the two signed 64-bit divides ((iters<<8)/iterw,
              // (itert<<8)/iterw) are now done by the radix-4 SRT divider (srt_div,
              // launched combinationally this cycle); wait for them in S_DIVW. The
              // result is BIT-IDENTICAL to the `/` it replaces (srt is verified vs
              // `/`), so the rendered pixels are unchanged -- it just removes the
              // ~70 ns combinational divide that pinned the design to ~14 MHz.
              // lod_persp = -log2(|1/W|, 32 frac); negative 1/W -> 0 (no divide).
              lod_persp_q <= iterw[63] ? 32'sd0
                                       : -vd_log2_int({64'd0, $unsigned(iterw)}, 32);
              state_q <= S_DIVW;
            end else begin                           // affine: /2^24 truncate toward zero
              coord_s_q   <= 32'(vd_asr_trunc64(iters, 24));
              coord_t_q   <= 32'(vd_asr_trunc64(itert, 24));
              lod_persp_q <= 32'sd0;
              state_q <= S_LODCALC;
            end
            negw_q  <= (iterw < 64'sd0);
`endif
          end

`ifdef VOODOO_INT
          S_DIVW: begin
            // SRT divides in flight (launched in S_DIV); capture when valid.
            if (srt_s_valid && srt_t_valid) begin
              coord_s_q <= srt_s_q[31:0];
              coord_t_q <= srt_t_q[31:0];
              state_q   <= S_LODCALC;
            end
          end
`endif

          S_LODCALC: begin
            logic signed [31:0] sv, tv;
            if (tp_q.texmode[3] && negw_q) begin
              sv = 32'sd0; tv = 32'sd0;
            end else begin
              sv = coord_s_q; tv = coord_t_q;
            end
            ilod_q    <= lc_ilod;
            texbase_q <= lodoff_q[lc_ilod];
            smax_q    <= lc_smax;
            tmax_q    <= lc_tmax;
            point_q   <= lc_point;
            corner_q  <= 2'd0;
            if (lc_point) begin
              int sh;
              logic signed [31:0] ss, tt;
              sh = int'(lc_ilod) + 8;
              ss = sv >>> sh;
              tt = tv >>> sh;
              if (tp_q.texmode[6]) ss = iclampf(ss, 0, int'(lc_smax));
              if (tp_q.texmode[7]) tt = iclampf(tt, 0, int'(lc_tmax));
              cs_ss <= 8'(ss) & lc_smax;
              cs_tt <= 8'(tt) & lc_tmax;
              cs_s1 <= 8'(ss) & lc_smax;
              cs_t1 <= 8'(tt) & lc_tmax;
            end else begin
              logic signed [31:0] ss, tt, s1, t1;
              ss = sv >>> int'(lc_ilod);
              tt = tv >>> int'(lc_ilod);
              ss = ss - 32'sd128;
              tt = tt - 32'sd128;
              sfrac_q <= 8'(ss[7:0] & 8'hf0);
              tfrac_q <= 8'(tt[7:0] & 8'hf0);
              ss = ss >>> 8;
              tt = tt >>> 8;
              s1 = ss + 32'sd1;
              t1 = tt + 32'sd1;
              if (tp_q.texmode[6]) begin
                if (ss < 0) begin ss = 0; s1 = 0; end
                else if (ss >= int'(lc_smax)) begin ss = int'(lc_smax); s1 = int'(lc_smax); end
              end
              if (tp_q.texmode[7]) begin
                if (tt < 0) begin tt = 0; t1 = 0; end
                else if (tt >= int'(lc_tmax)) begin tt = int'(lc_tmax); t1 = int'(lc_tmax); end
              end
              cs_ss <= 8'(ss) & lc_smax;
              cs_s1 <= 8'(s1) & lc_smax;
              cs_tt <= 8'(tt) & lc_tmax;
              cs_t1 <= 8'(t1) & lc_tmax;
              // s1/t1 upper bits only feed the (already-evaluated) clamp/mask;
              // sink them so lint sees the full width as consumed.  (Must NOT
              // be a conditional self-assignment to cs_ss: that issues a second
              // non-blocking write that overrides the correct value with the
              // stale one whenever s1[31:8] & t1[31:8] are all ones — i.e. for
              // small negative texel coords, which corrupted the bilinear base
              // corner on perspective walls.)
              cs_unused <= |{s1[31:8], t1[31:8]};
            end
            state_q <= S_ADDR;
          end

          S_ADDR:  state_q <= S_RDLAT;   // trd_addr driven; read launched
          S_RDLAT: state_q <= S_EXPAND;  // 1-cycle registered read -> data avail

          S_EXPAND: begin
            // form raw value, then it must settle through ex_* one more cycle
            logic [15:0] rv;
            if (!bpt2)
              rv = byte_hi ? {8'd0, trd_data[15:8]} : {8'd0, trd_data[7:0]};
            else
              rv = trd_data;
            raw_w   <= rv;
            state_q <= S_NEXT;
          end

          S_NEXT: begin
            // ex_* now reflects raw_w (set last cycle): store corner
            e_a[corner_q] <= ex_a;
            e_r[corner_q] <= ex_r;
            e_g[corner_q] <= ex_g;
            e_b[corner_q] <= ex_b;
            if (point_q) begin
              comb_q  <= tex_combine(tp_q.texmode, ex_r, ex_g, ex_b, ex_a);
              state_q <= S_RESP;
            end else if (corner_q == 2'd3) begin
              // all 4 corners captured (e_*[3] written this cycle); blend
              // next cycle once it has settled
              state_q <= S_BLEND;
            end else begin
              corner_q <= corner_q + 2'd1;
              state_q  <= S_ADDR;
            end
          end

          S_BLEND: begin
            comb_q  <= tex_combine(tp_q.texmode, bl_r, bl_g, bl_b, bl_a);
            state_q <= S_RESP;
          end

          S_RESP: begin
            if (tex_ready)
              state_q <= S_RDY;
          end

          default: state_q <= S_IDLE;
        endcase
      end
    end
  end

`ifdef VOODOO_INT
  // ----------------------------------------------------------------
  //  radix-4 SRT perspective divides (replaces the combinational `/`)
  //  S=(iters<<8)/iterw, T=(itert<<8)/iterw with a shared guarded divisor.
  //  Launched combinationally in S_DIV (perspective); captured in S_DIVW.
  // ----------------------------------------------------------------
  logic signed [63:0] srt_b;                       // guarded iterw (!=0)
  logic               srt_launch;
  logic signed [63:0] srt_s_q, srt_t_q, srt_s_r, srt_t_r;
  logic               srt_s_valid, srt_t_valid, srt_s_rdy, srt_t_rdy;
  logic               srt_s_derr, srt_t_derr;

  assign srt_b      = (w0_q == 64'sd0) ? 64'sd1 : w0_q;
  assign srt_launch = (state_q == S_DIV) && tp_q.texmode[0];

  srt_div #(.W(64)) u_srt_s (
      .clk(clk), .rst_n(rst_n),
      .in_valid(srt_launch), .in_ready(srt_s_rdy),
      .a($signed(s0_q) <<< 8), .b(srt_b),
      .out_valid(srt_s_valid), .q(srt_s_q), .r(srt_s_r), .derr(srt_s_derr));
  srt_div #(.W(64)) u_srt_t (
      .clk(clk), .rst_n(rst_n),
      .in_valid(srt_launch), .in_ready(srt_t_rdy),
      .a($signed(t0_q) <<< 8), .b(srt_b),
      .out_valid(srt_t_valid), .q(srt_t_q), .r(srt_t_r), .derr(srt_t_derr));

  // S_DIVW gates on out_valid; ready/remainder/derr are not needed here.
  logic srt_unused;
  assign srt_unused = &{1'b0, srt_s_q[63:32], srt_t_q[63:32], srt_s_r, srt_t_r,
                        srt_s_rdy, srt_t_rdy, srt_s_derr, srt_t_derr};
`endif

  // unused sink — tri_params fields not consumed by the TMU, the upper
  // texBaseAddr bits (only [18:0] matter), and a few derived bits.
  logic unused;
  assign unused = &{1'b0, cs_unused, texbaseaddr[31:19], texbase_lo_q, ilod_q, tmax_q,
                    tp_q.ax, tp_q.ay, tp_q.bx, tp_q.by, tp_q.cx, tp_q.cy,
                    tp_q.sign,
                    tp_q.startr, tp_q.startg, tp_q.startb, tp_q.starta,
                    tp_q.drdx, tp_q.dgdx, tp_q.dbdx, tp_q.dadx,
                    tp_q.drdy, tp_q.dgdy, tp_q.dbdy, tp_q.dady,
                    tp_q.startz, tp_q.dzdx, tp_q.dzdy,
                    tp_q.startw, tp_q.dwdx, tp_q.dwdy,
                    tp_q.s0, tp_q.t0, tp_q.w0, tp_q.dw0dx, tp_q.dw0dy,
                    tp_q.fbzmode, tp_q.fbzcp,
                    tp_q.alphamode, tp_q.fogmode,
                    tp_q.color0, tp_q.color1, tp_q.zacolor,
                    tp_q.stipple, tp_q.chromakey, tp_q.fogcolor,
                    tp_q.clip_left, tp_q.clip_right, tp_q.clip_top,
                    tp_q.clip_bottom, tp_q.dest_base, tp_q.aux_base,
                    tp_q.aux_valid, tp_q.rowpixels, tp_q.yorigin};

endmodule
