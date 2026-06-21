// voodoo_pkg.sv — shared constants, types and pure helpers.
// Contract-level file (docs/CONTRACTS.md); do not change field names/widths
// without updating the contract.
/* verilator lint_off UNUSEDPARAM */
package voodoo_pkg;

  // memory geometry: 4 MB framebuffer (2^21 x 16), 2 MB texture (2^20 x 16).
  // TEX_AW is overridable (+define+VOODOO_TEX_AW=NN) for FPGA targets whose on-chip
  // URAM cannot hold the full 2 MB texture (e.g. KV260/xck26 uses 17 = 128K x16 =
  // 32 URAM). Default 20 keeps `make test` at the full gold geometry, unchanged.
  localparam int unsigned FB_AW  = 21;
`ifdef VOODOO_TEX_AW
  localparam int unsigned TEX_AW = `VOODOO_TEX_AW;
`else
  localparam int unsigned TEX_AW = 20;
`endif

  // ---------------------------------------------------------------
  // register word indices (byte offset / 4) — SST-1, per voodoo_render.h
  // ---------------------------------------------------------------
  localparam logic [7:0] REG_STATUS        = 8'h00;
  localparam logic [7:0] REG_VERTEXAX      = 8'h02;
  localparam logic [7:0] REG_VERTEXAY      = 8'h03;
  localparam logic [7:0] REG_VERTEXBX      = 8'h04;
  localparam logic [7:0] REG_VERTEXBY      = 8'h05;
  localparam logic [7:0] REG_VERTEXCX      = 8'h06;
  localparam logic [7:0] REG_VERTEXCY      = 8'h07;
  localparam logic [7:0] REG_STARTR        = 8'h08;
  localparam logic [7:0] REG_STARTG        = 8'h09;
  localparam logic [7:0] REG_STARTB        = 8'h0a;
  localparam logic [7:0] REG_STARTZ        = 8'h0b;
  localparam logic [7:0] REG_STARTA        = 8'h0c;
  localparam logic [7:0] REG_STARTS        = 8'h0d;
  localparam logic [7:0] REG_STARTT        = 8'h0e;
  localparam logic [7:0] REG_STARTW        = 8'h0f;
  localparam logic [7:0] REG_DRDX          = 8'h10;
  localparam logic [7:0] REG_DGDX          = 8'h11;
  localparam logic [7:0] REG_DBDX          = 8'h12;
  localparam logic [7:0] REG_DZDX          = 8'h13;
  localparam logic [7:0] REG_DADX          = 8'h14;
  localparam logic [7:0] REG_DSDX          = 8'h15;
  localparam logic [7:0] REG_DTDX          = 8'h16;
  localparam logic [7:0] REG_DWDX          = 8'h17;
  localparam logic [7:0] REG_DRDY          = 8'h18;
  localparam logic [7:0] REG_DGDY          = 8'h19;
  localparam logic [7:0] REG_DBDY          = 8'h1a;
  localparam logic [7:0] REG_DZDY          = 8'h1b;
  localparam logic [7:0] REG_DADY          = 8'h1c;
  localparam logic [7:0] REG_DSDY          = 8'h1d;
  localparam logic [7:0] REG_DTDY          = 8'h1e;
  localparam logic [7:0] REG_DWDY          = 8'h1f;
  localparam logic [7:0] REG_TRIANGLECMD   = 8'h20;
  localparam logic [7:0] REG_FVERTEXAX     = 8'h22;  // float bank 0x22..0x3f
  localparam logic [7:0] REG_FDWDY         = 8'h3f;
  localparam logic [7:0] REG_FTRIANGLECMD  = 8'h40;
  localparam logic [7:0] REG_FBZCOLORPATH  = 8'h41;
  localparam logic [7:0] REG_FOGMODE       = 8'h42;
  localparam logic [7:0] REG_ALPHAMODE     = 8'h43;
  localparam logic [7:0] REG_FBZMODE       = 8'h44;
  localparam logic [7:0] REG_LFBMODE       = 8'h45;
  localparam logic [7:0] REG_CLIPLEFTRIGHT = 8'h46;
  localparam logic [7:0] REG_CLIPLOWYHIGHY = 8'h47;
  localparam logic [7:0] REG_NOPCMD        = 8'h48;
  localparam logic [7:0] REG_FASTFILLCMD   = 8'h49;
  localparam logic [7:0] REG_SWAPBUFFERCMD = 8'h4a;
  localparam logic [7:0] REG_FOGCOLOR      = 8'h4b;
  localparam logic [7:0] REG_ZACOLOR       = 8'h4c;
  localparam logic [7:0] REG_CHROMAKEY     = 8'h4d;
  localparam logic [7:0] REG_STIPPLE       = 8'h50;
  localparam logic [7:0] REG_COLOR0        = 8'h51;
  localparam logic [7:0] REG_COLOR1        = 8'h52;
  localparam logic [7:0] REG_FBIPIXELSIN   = 8'h53;
  localparam logic [7:0] REG_FBICHROMAFAIL = 8'h54;
  localparam logic [7:0] REG_FBIZFUNCFAIL  = 8'h55;
  localparam logic [7:0] REG_FBIAFUNCFAIL  = 8'h56;
  localparam logic [7:0] REG_FBIPIXELSOUT  = 8'h57;
  localparam logic [7:0] REG_FOGTABLE      = 8'h58;  // ..0x77
  localparam logic [7:0] REG_FBIINIT4      = 8'h80;
  localparam logic [7:0] REG_VRETRACE      = 8'h81;
  localparam logic [7:0] REG_BACKPORCH     = 8'h82;
  localparam logic [7:0] REG_VIDEODIMENSIONS = 8'h83;
  localparam logic [7:0] REG_FBIINIT0      = 8'h84;
  localparam logic [7:0] REG_FBIINIT1      = 8'h85;
  localparam logic [7:0] REG_FBIINIT2      = 8'h86;
  localparam logic [7:0] REG_FBIINIT3      = 8'h87;
  localparam logic [7:0] REG_HSYNC         = 8'h88;
  localparam logic [7:0] REG_VSYNC         = 8'h89;
  localparam logic [7:0] REG_CLUTDATA      = 8'h8a;
  localparam logic [7:0] REG_DACDATA       = 8'h8b;
  localparam logic [7:0] REG_TEXTUREMODE   = 8'hc0;
  localparam logic [7:0] REG_TLOD          = 8'hc1;
  localparam logic [7:0] REG_TDETAIL       = 8'hc2;
  localparam logic [7:0] REG_TEXBASEADDR   = 8'hc3;
  localparam logic [7:0] REG_TEXBASEADDR1  = 8'hc4;
  localparam logic [7:0] REG_TEXBASEADDR2  = 8'hc5;
  localparam logic [7:0] REG_TEXBASEADDR38 = 8'hc6;
  localparam logic [7:0] REG_TREXINIT0     = 8'hc7;
  localparam logic [7:0] REG_TREXINIT1     = 8'hc8;
  localparam logic [7:0] REG_NCCTABLE      = 8'hc9;

  // ---------------------------------------------------------------
  // triangle launch parameters (CONTRACTS.md §7.1)
  // ---------------------------------------------------------------
  typedef struct packed {
    // vertices, 12.4 signed
    logic signed [15:0] ax, ay, bx, by, cx, cy;
    // sign: bit31 of the (f)triangleCMD write data; 1 = AC is the right edge
    logic               sign;
    // color/alpha iterators: 12.12 stored in 32 (sign-extended from 24)
    logic signed [31:0] startr, startg, startb, starta;
    logic signed [31:0] drdx, dgdx, dbdx, dadx;
    logic signed [31:0] drdy, dgdy, dbdy, dady;
    // Z 20.12
    logic signed [31:0] startz, dzdx, dzdy;
    // FBI W 16.32
    logic signed [63:0] startw, dwdx, dwdy;
    // TMU0 S/T (14.18 <<14) and W0 (16.32) — carried now, consumed in M3
    logic signed [63:0] s0, ds0dx, ds0dy, t0, dt0dx, dt0dy, w0, dw0dx, dw0dy;
    // mode register snapshot
    logic [31:0] fbzmode, fbzcp, alphamode, fogmode, texmode, tlod;
    logic [31:0] color0, color1, zacolor;
    // M4: stipple register (0x50) and chromaKey (0x4d) and fogColor (0x4b)
    logic [31:0] stipple, chromakey, fogcolor;
    // effective clip rect, pixels; right/bottom exclusive
    logic [9:0]  clip_left, clip_right, clip_top, clip_bottom;
    // resolved buffers & layout (16-bit-word offsets into fb_ram)
    logic [FB_AW-1:0] dest_base;
    logic [FB_AW-1:0] aux_base;
    logic             aux_valid;
    logic [10:0]      rowpixels;
    logic [9:0]       yorigin;   // effective y-origin (CONTRACTS §9.5)
  } tri_params_t;

  // ---------------------------------------------------------------
  // dither (MAME dither_helper; matrices indexed [(y&3)*4 + (x&3)])
  // ---------------------------------------------------------------
  function automatic logic [3:0] dither_matrix(input logic use_2x2,
                                               input logic [1:0] x,
                                               input logic [1:0] y);
    logic [3:0] m4 [16];
    logic [3:0] m2 [16];
    m4 = '{4'd0, 4'd8, 4'd2, 4'd10,
           4'd12, 4'd4, 4'd14, 4'd6,
           4'd3, 4'd11, 4'd1, 4'd9,
           4'd15, 4'd7, 4'd13, 4'd5};
    m2 = '{4'd8, 4'd10, 4'd8, 4'd10,
           4'd11, 4'd9, 4'd11, 4'd9,
           4'd8, 4'd10, 4'd8, 4'd10,
           4'd11, 4'd9, 4'd11, 4'd9};
    return use_2x2 ? m2[{y, x}] : m4[{y, x}];
  endfunction

  // ((v<<1) - (v>>4) + (v>>7) + d) >> 4  — 5-bit result, never out of range
  function automatic logic [4:0] dith_rb(input logic [7:0] v, input logic [3:0] d);
    int t;
    t = ((int'(v) <<< 1) - (int'(v) >>> 4) + (int'(v) >>> 7) + int'(d)) >>> 4;
    return 5'(t);
  endfunction

  // ((v<<2) - (v>>4) + (v>>6) + d) >> 4  — 6-bit result
  function automatic logic [5:0] dith_g(input logic [7:0] v, input logic [3:0] d);
    int t;
    t = ((int'(v) <<< 2) - (int'(v) >>> 4) + (int'(v) >>> 6) + int'(d)) >>> 4;
    return 6'(t);
  endfunction

  // straight truncation 888 -> 565 (no dither)
  function automatic logic [15:0] pack565(input logic [7:0] r,
                                          input logic [7:0] g,
                                          input logic [7:0] b);
    return {r[7:3], g[7:2], b[7:3]};
  endfunction

  // dithered 888 -> 565 (use_dither selects; use_2x2 = fbzMode bit 11)
  function automatic logic [15:0] dither565(input logic [7:0] r,
                                            input logic [7:0] g,
                                            input logic [7:0] b,
                                            input logic use_dither,
                                            input logic use_2x2,
                                            input logic [1:0] x,
                                            input logic [1:0] y);
    logic [3:0] d;
    if (!use_dither) return pack565(r, g, b);
    d = dither_matrix(use_2x2, x, y);
    return {dith_rb(r, d), dith_g(g, d), dith_rb(b, d)};
  endfunction

  // 565 -> 888 with bit replication (matches gold from565)
  function automatic logic [23:0] unpack565(input logic [15:0] p);
    logic [4:0] r5;
    logic [5:0] g6;
    logic [4:0] b5;
    r5 = p[15:11]; g6 = p[10:5]; b5 = p[4:0];
    return {{r5, r5[4:2]}, {g6, g6[5:4]}, {b5, b5[4:2]}};
  endfunction

  // shared 8-way compare (depth_function / alphafunction encoding)
  function automatic logic cmp_pass(input logic [2:0] func,
                                    input logic [16:0] incoming,
                                    input logic [16:0] stored);
    case (func)
      3'd0: return 1'b0;
      3'd1: return incoming <  stored;
      3'd2: return incoming == stored;
      3'd3: return incoming <= stored;
      3'd4: return incoming >  stored;
      3'd5: return incoming != stored;
      3'd6: return incoming >= stored;
      default: return 1'b1;
    endcase
  endfunction

  // register alias map (fbiInit3 bit0, addr bit 21) — voodoo.c:73
  function automatic logic [7:0] alias_remap(input logic [5:0] idx);
    logic [7:0] map [64];
    map = '{8'h00, 8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07,
            8'h08, 8'h10, 8'h18, 8'h09, 8'h11, 8'h19, 8'h0a, 8'h12,
            8'h1a, 8'h0b, 8'h13, 8'h1b, 8'h0c, 8'h14, 8'h1c, 8'h0d,
            8'h15, 8'h1d, 8'h0e, 8'h16, 8'h1e, 8'h0f, 8'h17, 8'h1f,
            8'h20, 8'h21, 8'h22, 8'h23, 8'h24, 8'h25, 8'h26, 8'h27,
            8'h28, 8'h30, 8'h38, 8'h29, 8'h31, 8'h39, 8'h2a, 8'h32,
            8'h3a, 8'h2b, 8'h33, 8'h3b, 8'h2c, 8'h34, 8'h3c, 8'h2d,
            8'h35, 8'h3d, 8'h2e, 8'h36, 8'h3e, 8'h2f, 8'h37, 8'h3f};
    return map[idx];
  endfunction

  // ===============================================================
  //  VOODOO_INT — shared fixed-point helpers (PLAN §3.0, SPEC §4-§7)
  // ---------------------------------------------------------------
  //  Only referenced by the integer datapath (raster/tmu `else paths).
  //  Wrapped in `ifdef VOODOO_INT so INT=0 elaboration is byte-identical
  //  to the float baseline (no new symbols enter the package).
  // ===============================================================
`ifdef VOODOO_INT

  // ---------------------------------------------------------------
  // vd_clz64 — count leading zeros of a 64-bit value (leading-one
  // detect for the log2 / reciprocal normalize). Mirrors the linear
  // CLZ idiom in pixel_pipe.sv `clz64f` (wfloatf). v==0 -> 64.
  // ---------------------------------------------------------------
  function automatic int vd_clz64(input logic [63:0] v);
    int  n;
    bit  found;
    n = 0; found = 1'b0;
    for (int i = 63; i >= 0; i--) begin
      if (!found) begin
        if (v[i]) found = 1'b1;
        else      n = n + 1;
      end
    end
    return n;
  endfunction

  // ---------------------------------------------------------------
  // vd_log2_mant — 128x8 mantissa LUT, ideal value round(256*log2(1.m))
  // on 7 mantissa bits.  [UNSPEC-BY-DOC] (SPEC §6.2).
  // DEVIATION (intentional, RMSE-driven): the contents are NOT the
  // arithmetically rounded round(256*log2(1.m)); they are the EXACT
  // values of the MAME-derived s_log2_table already used by the FLOAT
  // baseline (tmu.sv `log2tab`, voodoo_gold.c `s_log2_table`). Reusing
  // the identical entries makes vd_log2_int bit-for-bit match the float
  // `fast_log2f` (verified: 0 mismatches / 1e6 samples), so the log2
  // path contributes ZERO RMSE vs INT=0. A few entries differ from the
  // true round() by 1 LSB (e.g. idx 1: tab=2 vs round=3) — that is the
  // baseline table's own rounding and is preserved on purpose.
  // ---------------------------------------------------------------
  function automatic logic [7:0] vd_log2_mant(input logic [6:0] m);
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

  // ---------------------------------------------------------------
  // vd_log2_int — integer log2 of a (>=0) fixed-point value, returned
  // as signed x.8 (8 fraction bits, the "24.8" carrier). CLZ leading-one
  // detect gives floor_log2; the 7 bits below the leading one index
  // vd_log2_mant for the fractional part.  SPEC §6.1/§6.2.
  //   exp  = floor_log2(value) - fracbits        (integer part, de-scaled)
  //   frac = vd_log2_mant(7 bits below leading 1)
  //   return (exp << 8) | frac ;  value <= 0 -> 0
  // Bit-exact to the float `fast_log2f` (which does the same exponent
  // extraction on the IEEE-754 pattern + the same mantissa table).
  // 128-bit operand supports the §6.1 sum-of-squares (fracbits=64).
  // ---------------------------------------------------------------
  function automatic logic signed [31:0] vd_log2_int(input logic [127:0] value,
                                                     input int fracbits);
    int                 lead;   // index of the leading one (floor_log2)
    int                 clz;    // leading zeros in 128 bits
    logic [6:0]         midx;   // 7 mantissa bits below the leading one
    logic signed [23:0] expv;   // integer part of log2, de-scaled (24.- carrier)
    if (value == 128'd0)
      return 32'sd0;
    // CLZ over 128 bits via two 64-bit halves (reuse vd_clz64).
    if (value[127:64] != 64'd0) clz = vd_clz64(value[127:64]);
    else                        clz = 64 + vd_clz64(value[63:0]);
    lead = 127 - clz;                          // leading-one bit position
    // 7 mantissa bits immediately below the leading one
    if (lead >= 7) midx = 7'(value >> (lead - 7));
    else           midx = 7'(value << (7 - lead));
    expv = 24'(lead - fracbits);
    return $signed({expv, 8'd0} | {24'd0, vd_log2_mant(midx)});
  endfunction

  // ---------------------------------------------------------------
  // Reciprocal-unit scaling (SPEC §5.2 / PLAN §3.2 Edit C).
  //   The TMU perspective divide computes coord = (S/W) * (256/iterw).
  //   The float baseline does `recip = 256.0/iterw; coord = rtoi(iters*recip)`
  //   so coord_raw = iters_raw * 256 / iterw_raw (truncate toward zero),
  //   landing 8 fraction bits at the bottom of coord (SPEC §7).
  //   vd_recip_w returns recip_scaled ~= round((256 << R_SCALE)/iterw_raw),
  //   so the caller forms  coord = (iters * recip_scaled) >>> R_SCALE.
  //   R_SCALE=30 keeps recip within signed-32 and iters(<=2^31) * recip
  //   within signed-64 (<= 2^62), while preserving >=18 reciprocal bits.
  // ---------------------------------------------------------------
  localparam int R_SCALE      = 30;   // fixed point of vd_recip_w output
  localparam int RW_MANT_BITS = 9;    // reciprocal mantissa LUT index width (>=7)
  localparam int RW_FRAC_BITS = 18;   // reciprocal LUT mantissa fraction (>=18 bits)

  // ---------------------------------------------------------------
  // vd_recip_w — integer reciprocal 256/iterw, scaled by 2^R_SCALE,
  // signed.  [UNSPEC-BY-DOC] (SPEC §5.2).  iterw is the 1/W iterator
  // (2.30 signed, carried s64).
  //   * leading-one normalize |iterw| = 1.m * 2^p   (vd_clz64)
  //   * recip mantissa LUT keyed on RW_MANT_BITS bits below the leading one,
  //     2^RW_FRAC_BITS / (1.m)
  //   * one Newton-Raphson step  r1 = r0*(2 - x*r0)  to reach >=18 result bits
  //   * shift to the R_SCALE*256 scale, apply sign
  // DEVIATION: no 3dfx doc pins the table size; widths (RW_MANT_BITS/
  // RW_FRAC_BITS) are the [UNSPEC-BY-DOC] free parameters to be swept
  // against the RMSE harness (PLAN §6 risk 1). At {9,18,30} the coord
  // error vs the float divide is <=1 LSB of 8.8 (1/256 texel) across the
  // realistic perspective range (verified in Python prototype).
  // ---------------------------------------------------------------
  function automatic logic signed [31:0] vd_recip_w(input logic signed [63:0] iterw);
    logic signed [63:0] w;
    logic [63:0]        a;        // |iterw|
    bit                 sign;
    int                 p;        // leading-one position of a
    logic [RW_MANT_BITS-1:0] midx;
    logic [127:0]       r0, xn, t, r1;
    logic [127:0]       val;
    int                 sh;
    // recip mantissa LUT: 2^RW_FRAC_BITS / (1 + i/2^RW_MANT_BITS), keyed on the
    // RW_MANT_BITS bits below the leading one. Built with integer arithmetic
    // (numerator 2^(RW_FRAC_BITS+RW_MANT_BITS) fits a longint) to avoid any
    // packed-width truncation; rounded to nearest.
    logic [RW_FRAC_BITS:0] rtab [1<<RW_MANT_BITS];
    longint unsigned       num, den;
    num = (longint'(1) << (RW_FRAC_BITS + RW_MANT_BITS));   // 2^F * 2^N
    for (int i = 0; i < (1<<RW_MANT_BITS); i++) begin
      den     = (longint'(1) << RW_MANT_BITS) + longint'(i); // 2^N + i  == (1.m)*2^N
      rtab[i] = (RW_FRAC_BITS+1)'((num + (den >> 1)) / den);
    end

    w = iterw;
    if (w == 64'sd0) w = 64'sd1;                 // div-by-zero guard (matches float)
    sign = w[63];
    a    = sign ? (~w + 64'd1) : w;              // |iterw|
    p    = 63 - vd_clz64(a);                     // leading-one position (a != 0)

    // RW_MANT_BITS bits just below the leading one
    if (p >= RW_MANT_BITS) midx = RW_MANT_BITS'(a >> (p - RW_MANT_BITS));
    else                   midx = RW_MANT_BITS'(a << (RW_MANT_BITS - p));
    r0 = 128'(rtab[midx]);                        // ~ 2^RW_FRAC_BITS / (1.m)

    // normalized mantissa xn = 1.m * 2^RW_FRAC_BITS (align leading one to bit RW_FRAC_BITS)
    if (p >= RW_FRAC_BITS) xn = 128'(a >> (p - RW_FRAC_BITS));
    else                   xn = 128'(a << (RW_FRAC_BITS - p));

    // Newton: r1 = r0*(2^(F+1) - xn*r0 >> F) >> F   (F = RW_FRAC_BITS)
    t  = (128'd2 << RW_FRAC_BITS) - ((xn * r0) >> RW_FRAC_BITS);
    r1 = (r0 * t) >> RW_FRAC_BITS;                // refined 2^RW_FRAC_BITS / (1.m)

    // recip(|iterw|) = r1 * 2^-(RW_FRAC_BITS + p).
    // recip_scaled = recip * 256 * 2^R_SCALE  ->  shift r1 by R_SCALE+8-(F+p)
    sh  = R_SCALE + 8 - (RW_FRAC_BITS + p);
    val = (sh >= 0) ? (r1 << sh) : (r1 >> (-sh));
    if (val > 128'sd2147483647) val = 128'sd2147483647;   // saturate to s32
    return sign ? -$signed(32'(val)) : $signed(32'(val));
  endfunction

  // ---------------------------------------------------------------
  // vd_asr_trunc64 — arithmetic shift right TRUNCATING TOWARD ZERO
  // (NOT floor), matching the float `$rtoi`/affine `>>24` intent
  // (SPEC §5.2 / PLAN §6 risk 4). For v<0, `>>>` would floor; here we
  // negate, logical-shift the magnitude, and negate back.
  // ---------------------------------------------------------------
  function automatic logic signed [63:0] vd_asr_trunc64(input logic signed [63:0] v,
                                                        input int n);
    logic [63:0] mag;
    if (v < 64'sd0) begin
      mag = (~v) + 64'd1;          // |v|
      return -$signed(mag >> n);   // truncate magnitude toward zero
    end else begin
      return $signed(v >> n);
    end
  endfunction

  // ---------------------------------------------------------------
  // vd_edge_x — S11.4 edge-X at the CENTER of scanline y (DDA, SPEC §4.3).
  // Edge anchor (x0,y0) in S11.4; slope = dX/dY (dimensionless) carried at
  // 2^VD_SLOPE_FRAC (s64). Edge X = x0 + (y_center - y0)*slope, sampled at the
  // row center (y+0.5 => +8 in S11.4) and shifted back by VD_SLOPE_FRAC —
  // matching the float round_coordinate(v1x + (y+0.5 - v1y)*slope) to
  // truncation, with enough fraction bits that long edges don't drift.
  // ---------------------------------------------------------------
  localparam int VD_SLOPE_FRAC = 20;   // edge-slope fraction bits (near-exact DDA)
  function automatic logic signed [31:0] vd_edge_x(input logic signed [31:0] x0_s11_4,
                                                   input logic signed [31:0] y0_s11_4,
                                                   input logic signed [63:0] slope_fp,
                                                   input logic signed [31:0] y);
    logic signed [63:0] dyf;     // (y_center - y0) in 1/16-row units (S11.4 domain)
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [63:0] xe;      // upper bits intentionally dropped (returns S11.4)
    /* verilator lint_on UNUSEDSIGNAL */
    dyf = (64'($signed(y)) <<< 4) + 64'sd8 - 64'($signed(y0_s11_4));
    xe  = 64'($signed(x0_s11_4)) + ((dyf * slope_fp) >>> VD_SLOPE_FRAC);
    return 32'(xe);
  endfunction

  // ---------------------------------------------------------------
  // vd_round_s11_4 — round an S11.4 coordinate to the nearest integer
  // pixel, ties (exactly .5) rounding DOWN: (x + 7) >>> 4. Matches the
  // float round_coordinate (MAME poly.h) and SpinalVoodoo center
  // sampling, so the integer coverage selects the SAME pixels as the
  // float baseline. (Was a top-left ceil (x+15)>>4, which shifted spans
  // ~1px and showed up as edge seams (m2) and texture swim (m5).)
  // ---------------------------------------------------------------
  function automatic logic signed [31:0] vd_round_s11_4(input logic signed [31:0] x_s11_4);
    return $signed((x_s11_4 + 32'sd7) >>> 4);
  endfunction

`endif // VOODOO_INT

endpackage
