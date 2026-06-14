// voodoo_pkg.sv — shared constants, types and pure helpers.
// Contract-level file (docs/CONTRACTS.md); do not change field names/widths
// without updating the contract.
/* verilator lint_off UNUSEDPARAM */
package voodoo_pkg;

  // memory geometry: 4 MB framebuffer (2^21 x 16), 2 MB texture (2^20 x 16)
  localparam int unsigned FB_AW  = 21;
  localparam int unsigned TEX_AW = 20;

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

endpackage
