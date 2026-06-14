// voodoo_regfile.sv — CONTRACTS §5/§6: 256x32 register file + 64-bit S/T/W shadow
// registers, float-bank ingest (float_conv), derived video-memory state, dacData
// FSM, buffer rotation on swap, status read assembly, fbiPixelsOut accumulation.
// Behavior ported from voodoo_soft.c (soft_reg_write/soft_reg_read/
// recompute_video_memory/recompute_dims/set_stw) with CONTRACTS §9 applied.
module voodoo_regfile
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // write port (from cmd_dispatch; regnum is post-alias, data post-swizzle)
    input  logic        wr_en,
    input  logic [7:0]  wr_regnum,
    input  logic [31:0] wr_data,

    // swapbufferCMD (immediate rotate, CONTRACTS §9.4)
    input  logic        swap_en,

    // combinational read port (post-alias regnum)
    input  logic [7:0]  rd_regnum,
    output logic [31:0] rd_data,

    // status read inputs (CONTRACTS §6) + assembled status value
    input  logic [6:0]  fifo_free,        // 0..64 free FIFO entries
    input  logic        busy,
    input  logic [31:0] init_enable,
    output logic [31:0] status_value,

    // fbiPixelsOut increments (LFB raw writes; pixel pipe)
    input  logic [1:0]  pixout_cnt_lfb,
    input  logic        pixout_inc_pipe,

    // decode state for reg_decode (CONTRACTS §2; sampled at FIFO pop)
    output logic        dec_swizzle_en,   // fbiInit0 bit 3
    output logic        dec_alias_en,     // fbiInit3 bit 0

    // M4 fog-table read port (pixel_pipe drives idx, gets {blend,delta})
    input  logic [5:0]  fog_rd_idx,
    output logic [7:0]  fog_rd_blend,
    output logic [7:0]  fog_rd_delta,

    // live register values (snapshot consumers: dispatch/lfb/fastfill/tex_dl)
    output logic [31:0] fbzmode,
    output logic [31:0] fbzcp,
    output logic [31:0] alphamode,
    output logic [31:0] fogmode,
    output logic [31:0] texmode,
    output logic [31:0] tlod,
    output logic [31:0] lfbmode,
    output logic [31:0] color0,
    output logic [31:0] color1,
    output logic [31:0] zacolor,
    output logic [31:0] clip_lr,
    output logic [31:0] clip_yy,
    output logic [31:0] texbaseaddr,
    output logic [31:0] stipple,    // M4 reg 0x50
    output logic [31:0] chromakey,  // M4 reg 0x4d
    output logic [31:0] fogcolor,   // M4 reg 0x4b

    // raw vertex / iterator registers
    output logic [15:0] vtx_ax, vtx_ay, vtx_bx, vtx_by, vtx_cx, vtx_cy,
    output logic [31:0] it_startr, it_startg, it_startb, it_starta, it_startz,
    output logic [31:0] it_drdx, it_dgdx, it_dbdx, it_dadx, it_dzdx,
    output logic [31:0] it_drdy, it_dgdy, it_dbdy, it_dady, it_dzdy,

    // 64-bit S/T/W shadows (<<14 / <<2 / float_to_int64 ingest)
    output logic signed [63:0] sh_s, sh_dsdx, sh_dsdy,
    output logic signed [63:0] sh_t, sh_dtdx, sh_dtdy,
    output logic signed [63:0] sh_w, sh_dwdx, sh_dwdy,

    // derived layout state
    output logic [10:0]      rowpixels,
    output logic [9:0]       width,
    output logic [9:0]       height,
    output logic [9:0]       yorigin,        // raw fbiInit3[31:22]
    output logic [FB_AW-1:0] rgboffs_w [4],  // [3] is a hard-invalid slot
    output logic [3:0]       rgboffs_valid,
    output logic [FB_AW-1:0] auxoffs_w,
    output logic             auxoffs_valid,
    output logic [1:0]       frontbuf,
    output logic [1:0]       backbuf
);

  // ----------------------------------------------------------------
  // storage
  // ----------------------------------------------------------------
  logic [31:0] regs [0:255];

  logic signed [63:0] sh_s_q, sh_dsdx_q, sh_dsdy_q;
  logic signed [63:0] sh_t_q, sh_dtdx_q, sh_dtdy_q;
  logic signed [63:0] sh_w_q, sh_dwdx_q, sh_dwdy_q;

  logic [10:0]      rowpixels_q;
  logic [9:0]       width_q, height_q, yorigin_q;
  logic [FB_AW-1:0] rgb1off_q, rgb2off_q, auxoff_q;
  logic             rgb2valid_q, auxvalid_q;
  logic [1:0]       frontbuf_q, backbuf_q;

  logic [7:0] dac_regs [0:7];
  logic [7:0] dac_rd_q;

  // M4 fog tables (MAME m_fogblend/m_fogdelta), 64 u8 entries each. A write to
  // fogTable index k (regnum 0x58..0x77) sets base = 2*(k - 0x58):
  //   fogdelta[base]=data[7:0]; fogblend[base]=data[15:8];
  //   fogdelta[base+1]=data[23:16]; fogblend[base+1]=data[31:24].
  logic [7:0] fogblend_q [0:63];
  logic [7:0] fogdelta_q [0:63];
  logic       is_fogtable;
  logic [5:0] fog_base;
  always_comb begin
    is_fogtable = (wr_regnum >= REG_FOGTABLE) && (wr_regnum <= 8'h77);
    fog_base    = {(wr_regnum[4:0] - REG_FOGTABLE[4:0]), 1'b0};
  end

  // ----------------------------------------------------------------
  // write-path classification (voodoo_soft.c soft_reg_write)
  // ----------------------------------------------------------------
  function automatic logic is_stw_reg(input logic [7:0] r);
    return (r == REG_STARTS) || (r == REG_STARTT) || (r == REG_STARTW) ||
           (r == REG_DSDX)   || (r == REG_DTDX)   || (r == REG_DWDX)   ||
           (r == REG_DSDY)   || (r == REG_DTDY)   || (r == REG_DWDY);
  endfunction

  logic       is_float;
  logic [7:0] eff_target;     // float-bank regs map to target = regnum - 0x20
  logic       tgt_is_stw;
  logic       tgt_is_w;       // startW/dWdX/dWdY (fixed ingest <<2 vs <<14)

  always_comb begin
    is_float   = (wr_regnum >= REG_FVERTEXAX) && (wr_regnum <= REG_FDWDY);
    eff_target = is_float ? (wr_regnum - 8'h20) : wr_regnum;
    tgt_is_stw = is_stw_reg(eff_target);
    tgt_is_w   = (eff_target == REG_STARTW) || (eff_target == REG_DWDX) ||
                 (eff_target == REG_DWDY);
  end

  // float conversion (fixedbits: 4 = vertices, 12 = colors/Z, 32 = S/T/W)
  logic [5:0]  fc_fixedbits;
  logic [31:0] fc_out32;
  logic [63:0] fc_out64;

  always_comb begin
    if (tgt_is_stw)
      fc_fixedbits = 6'd32;
    else if ((eff_target >= REG_VERTEXAX) && (eff_target <= REG_VERTEXCY))
      fc_fixedbits = 6'd4;
    else
      fc_fixedbits = 6'd12;
  end

  float_conv u_float_conv (
      .data      (wr_data),
      .fixedbits (fc_fixedbits),
      .out32     (fc_out32),
      .out64     (fc_out64)
  );

  // fixed-point S/T/W ingest value (set_stw): S/T <<14, W <<2; float path -> f64
  logic signed [63:0] stw_val;
  always_comb begin
    logic signed [63:0] sx;
    sx = 64'($signed(wr_data));
    if (is_float)        stw_val = $signed(fc_out64);
    else if (tgt_is_w)   stw_val = sx <<< 2;
    else                 stw_val = sx <<< 14;
  end

  // recompute_video_memory inputs (uses post-write values of fbiInit1/2)
  logic [8:0]  buffer_pages;
  logic        triple_buf;
  logic [4:0]  xtiles;

  always_comb begin
    if (wr_regnum == REG_FBIINIT2) begin
      buffer_pages = wr_data[19:11];
      triple_buf   = wr_data[4];
    end else begin
      buffer_pages = regs[REG_FBIINIT2][19:11];
      triple_buf   = regs[REG_FBIINIT2][4];
    end
    if (wr_regnum == REG_FBIINIT1)
      xtiles = {wr_data[24], wr_data[7:4]};
    else
      xtiles = {regs[REG_FBIINIT1][24], regs[REG_FBIINIT1][7:4]};
  end

  // unused input bits (kept for interface completeness)
  logic unused_in;
  assign unused_in = &{1'b0, fifo_free[0], init_enable[31:3], init_enable[1:0]};

  // swap rotation: buffers = triple ? 3 : 2; front = (front+1)%buffers
  function automatic logic [1:0] rot_buf(input logic [1:0] b, input logic three);
    logic [1:0] n;
    n = b + 2'd1;          // 0..3 (wraps)
    if (three) begin
      if (n == 2'd3) n = 2'd0;
    end else begin
      if (n >= 2'd2) n = n - 2'd2;
    end
    return n;
  endfunction

  // ----------------------------------------------------------------
  // state update
  // ----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 256; i++)
        regs[i] <= 32'h0;
      sh_s_q <= '0; sh_dsdx_q <= '0; sh_dsdy_q <= '0;
      sh_t_q <= '0; sh_dtdx_q <= '0; sh_dtdy_q <= '0;
      sh_w_q <= '0; sh_dwdx_q <= '0; sh_dwdy_q <= '0;
      // defaults per CONTRACTS §3 (voodoo.c realize): 640x480, rowpixels 640,
      // rgboffs {0, 1MB, invalid}, aux 2MB, frontbuf 0, backbuf 1
      rowpixels_q <= 11'd640;
      width_q     <= 10'd640;
      height_q    <= 10'd480;
      yorigin_q   <= 10'd0;
      rgb1off_q   <= 21'h080000;   // 1 MB bytes -> 16-bit words
      rgb2off_q   <= 21'h0;
      rgb2valid_q <= 1'b0;
      auxoff_q    <= 21'h100000;   // 2 MB bytes -> 16-bit words
      auxvalid_q  <= 1'b1;
      frontbuf_q  <= 2'd0;
      backbuf_q   <= 2'd1;
      for (int i = 0; i < 8; i++)
        dac_regs[i] <= 8'h0;
      dac_rd_q <= 8'h0;
      for (int i = 0; i < 64; i++) begin
        fogblend_q[i] <= 8'h0;
        fogdelta_q[i] <= 8'h0;
      end
    end else begin
      // fbiPixelsOut accumulation (serialized: never concurrent with a
      // dispatch write to the same register; a wr_en write below wins)
      regs[REG_FBIPIXELSOUT] <= regs[REG_FBIPIXELSOUT]
                              + {30'b0, pixout_cnt_lfb}
                              + {31'b0, pixout_inc_pipe};

      if (wr_en) begin
        if (tgt_is_stw) begin
          // S/T/W iterators live only in the 64-bit shadows (set_stw)
          case (eff_target)
            REG_STARTS: sh_s_q     <= stw_val;
            REG_DSDX:   sh_dsdx_q  <= stw_val;
            REG_DSDY:   sh_dsdy_q  <= stw_val;
            REG_STARTT: sh_t_q     <= stw_val;
            REG_DTDX:   sh_dtdx_q  <= stw_val;
            REG_DTDY:   sh_dtdy_q  <= stw_val;
            REG_STARTW: sh_w_q     <= stw_val;
            REG_DWDX:   sh_dwdx_q  <= stw_val;
            default:    sh_dwdy_q  <= stw_val;   // REG_DWDY
          endcase
        end else if (is_float) begin
          regs[eff_target] <= fc_out32;
        end else begin
          case (wr_regnum)
            REG_FBIINIT1, REG_FBIINIT2: begin
              regs[wr_regnum] <= wr_data;
              rgb1off_q <= {1'b0, buffer_pages, 11'b0};  // pages*0x1000 B >> 1
              if (triple_buf) begin
                rgb2off_q   <= {buffer_pages, 12'b0};    // 2*pages*0x1000 B >> 1
                rgb2valid_q <= 1'b1;
                auxvalid_q  <= 1'b0;
              end else begin
                rgb2valid_q <= 1'b0;
                auxoff_q    <= {buffer_pages, 12'b0};
                auxvalid_q  <= 1'b1;
              end
              if (xtiles != 5'd0)
                rowpixels_q <= {xtiles, 6'b0};           // xtiles * 64
            end
            REG_FBIINIT3: begin
              regs[wr_regnum] <= wr_data;
              yorigin_q <= wr_data[31:22];
            end
            REG_VIDEODIMENSIONS: begin
              regs[wr_regnum] <= wr_data;
              if ((wr_data[9:0] != 10'd0) && (wr_data[25:16] != 10'd0)) begin
                width_q  <= wr_data[9:0];
                height_q <= wr_data[25:16];
              end
            end
            REG_DACDATA: begin
              // RAMDAC access FSM incl. 0x55/0x71/0x79 chip identification
              // (voodoo_soft.c REG_dacData handler)
              regs[wr_regnum] <= wr_data;
              if (wr_data[13:12] == 2'b00) begin         // rn < 8
                if (!wr_data[11]) begin
                  dac_regs[wr_data[10:8]] <= wr_data[7:0];
                end else begin
                  case (dac_regs[7])
                    8'h01:   dac_rd_q <= 8'h55;
                    8'h07:   dac_rd_q <= 8'h71;
                    8'h0b:   dac_rd_q <= 8'h79;
                    default: dac_rd_q <= dac_regs[wr_data[10:8]];
                  endcase
                end
              end
            end
            default: regs[wr_regnum] <= wr_data;
          endcase
        end
        // M4 fogTable decode (parallel to the reg store above; gold reg_write
        // also keeps g->regs[regnum]=data so the default branch covers that).
        if (is_fogtable) begin
          fogdelta_q[fog_base]              <= wr_data[7:0];
          fogblend_q[fog_base]              <= wr_data[15:8];
          fogdelta_q[fog_base + 6'd1]       <= wr_data[23:16];
          fogblend_q[fog_base + 6'd1]       <= wr_data[31:24];
        end
      end

      if (swap_en) begin
        frontbuf_q <= rot_buf(frontbuf_q, rgb2valid_q);
        backbuf_q  <= rot_buf(rot_buf(frontbuf_q, rgb2valid_q), rgb2valid_q);
      end
    end
  end

  // ----------------------------------------------------------------
  // reads
  // ----------------------------------------------------------------
  always_comb begin
    // CONTRACTS §6 status layout
    status_value = {4'h0,                       // [31:28]
                    16'hffff,                   // [27:12] memory FIFO empty
                    frontbuf_q,                 // [11:10]
                    {3{busy}},                  // [9:7]
                    1'b1,                       // [6]
                    fifo_free[6:1]};            // [5:0] = min(free/2, 0x3f)
  end

  always_comb begin
    if (rd_regnum == REG_STATUS)
      rd_data = status_value;
    else if ((rd_regnum == REG_FBIINIT2) && init_enable[2])
      rd_data = {24'h0, dac_rd_q};              // initEnable bit2 read remap
    else
      rd_data = regs[rd_regnum];
  end

  // ----------------------------------------------------------------
  // continuous outputs
  // ----------------------------------------------------------------
  assign dec_swizzle_en = regs[REG_FBIINIT0][3];
  assign dec_alias_en   = regs[REG_FBIINIT3][0];

  assign fbzmode     = regs[REG_FBZMODE];
  assign fbzcp       = regs[REG_FBZCOLORPATH];
  assign alphamode   = regs[REG_ALPHAMODE];
  assign fogmode     = regs[REG_FOGMODE];
  assign texmode     = regs[REG_TEXTUREMODE];
  assign tlod        = regs[REG_TLOD];
  assign lfbmode     = regs[REG_LFBMODE];
  assign color0      = regs[REG_COLOR0];
  assign color1      = regs[REG_COLOR1];
  assign zacolor     = regs[REG_ZACOLOR];
  assign clip_lr     = regs[REG_CLIPLEFTRIGHT];
  assign clip_yy     = regs[REG_CLIPLOWYHIGHY];
  assign texbaseaddr = regs[REG_TEXBASEADDR];
  assign stipple     = regs[REG_STIPPLE];
  assign chromakey   = regs[REG_CHROMAKEY];
  assign fogcolor    = regs[REG_FOGCOLOR];

  // M4 fog-table read port (combinational; pixel_pipe latches the result)
  assign fog_rd_blend = fogblend_q[fog_rd_idx];
  assign fog_rd_delta = fogdelta_q[fog_rd_idx];

  assign vtx_ax = regs[REG_VERTEXAX][15:0];
  assign vtx_ay = regs[REG_VERTEXAY][15:0];
  assign vtx_bx = regs[REG_VERTEXBX][15:0];
  assign vtx_by = regs[REG_VERTEXBY][15:0];
  assign vtx_cx = regs[REG_VERTEXCX][15:0];
  assign vtx_cy = regs[REG_VERTEXCY][15:0];

  assign it_startr = regs[REG_STARTR];
  assign it_startg = regs[REG_STARTG];
  assign it_startb = regs[REG_STARTB];
  assign it_starta = regs[REG_STARTA];
  assign it_startz = regs[REG_STARTZ];
  assign it_drdx   = regs[REG_DRDX];
  assign it_dgdx   = regs[REG_DGDX];
  assign it_dbdx   = regs[REG_DBDX];
  assign it_dadx   = regs[REG_DADX];
  assign it_dzdx   = regs[REG_DZDX];
  assign it_drdy   = regs[REG_DRDY];
  assign it_dgdy   = regs[REG_DGDY];
  assign it_dbdy   = regs[REG_DBDY];
  assign it_dady   = regs[REG_DADY];
  assign it_dzdy   = regs[REG_DZDY];

  assign sh_s    = sh_s_q;
  assign sh_dsdx = sh_dsdx_q;
  assign sh_dsdy = sh_dsdy_q;
  assign sh_t    = sh_t_q;
  assign sh_dtdx = sh_dtdx_q;
  assign sh_dtdy = sh_dtdy_q;
  assign sh_w    = sh_w_q;
  assign sh_dwdx = sh_dwdx_q;
  assign sh_dwdy = sh_dwdy_q;

  assign rowpixels = rowpixels_q;
  assign width     = width_q;
  assign height    = height_q;
  assign yorigin   = yorigin_q;

  assign rgboffs_w[0]  = '0;
  assign rgboffs_w[1]  = rgb1off_q;
  assign rgboffs_w[2]  = rgb2off_q;
  assign rgboffs_w[3]  = '0;
  assign rgboffs_valid = {1'b0, rgb2valid_q, 1'b1, 1'b1};
  assign auxoffs_w     = auxoff_q;
  assign auxoffs_valid = auxvalid_q;
  assign frontbuf      = frontbuf_q;
  assign backbuf       = backbuf_q;

endmodule
