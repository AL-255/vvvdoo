// cmd_dispatch.sv — CONTRACTS §5/§7: pops ONE FIFO command at a time (fully
// serialized), decodes per §2 at pop time, routes reg writes / LFB / texture /
// fastfill / swap / nop, executes drained reads, and builds tri_params_t with
// the docs/raster-algorithm.md §2 subpixel start adjustment (fbzcp bit 26).
module cmd_dispatch
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // FIFO head (host_if)
    input  logic        cmd_valid,
    output logic        cmd_pop,
    input  logic        cmd_is_write,
    input  logic [23:2] cmd_addr,
    input  logic [31:0] cmd_data,
    input  logic [3:0]  cmd_be,

    // read execution response (to host_if)
    output logic        rd_resp_valid,
    output logic [31:0] rd_resp_data,

    // regfile control
    output logic        rf_wr_en,
    output logic [7:0]  rf_wr_regnum,
    output logic [31:0] rf_wr_data,
    output logic        rf_swap,
    output logic [7:0]  rf_rd_regnum,
    input  logic [31:0] rf_rd_data,
    input  logic        dec_swizzle_en,
    input  logic        dec_alias_en,

    // regfile snapshot inputs
    input  logic [31:0] fbzmode, fbzcp, alphamode, fogmode, texmode, tlod,
    input  logic [31:0] color0, color1, zacolor, clip_lr, clip_yy,
    input  logic [15:0] vtx_ax, vtx_ay, vtx_bx, vtx_by, vtx_cx, vtx_cy,
    input  logic [31:0] it_startr, it_startg, it_startb, it_starta, it_startz,
    input  logic [31:0] it_drdx, it_dgdx, it_dbdx, it_dadx, it_dzdx,
    input  logic [31:0] it_drdy, it_dgdy, it_dbdy, it_dady, it_dzdy,
    input  logic signed [63:0] sh_s, sh_dsdx, sh_dsdy,
    input  logic signed [63:0] sh_t, sh_dtdx, sh_dtdy,
    input  logic signed [63:0] sh_w, sh_dwdx, sh_dwdy,
    input  logic [10:0] rowpixels,
    input  logic [9:0]  width, height, yorigin,
    input  logic [FB_AW-1:0] rgboffs_w [4],
    input  logic [3:0]       rgboffs_valid,
    input  logic [FB_AW-1:0] auxoffs_w,
    input  logic             auxoffs_valid,
    input  logic [1:0]  frontbuf, backbuf,

    // lfb_unit
    output logic        lfb_wr_valid,
    output logic [19:0] lfb_wr_dwoff,
    output logic [31:0] lfb_wr_data,
    output logic [3:0]  lfb_wr_be,
    input  logic        lfb_wr_done,
    output logic        lfb_rd_valid,
    output logic [19:0] lfb_rd_dwoff,
    input  logic        lfb_rd_done,
    input  logic [31:0] lfb_rd_data,

    // tex_dl
    output logic        tex_wr_valid,
    output logic [20:0] tex_wr_dwoff,
    output logic [31:0] tex_wr_data,
    input  logic        tex_wr_done,

    // fastfill (parameters are valid while ff_go pulses)
    output logic        ff_go,
    input  logic        ff_done,
    output logic [9:0]  ff_clip_left, ff_clip_right, ff_clip_top, ff_clip_bottom,
    output logic [31:0] ff_color1,
    output logic [15:0] ff_zfill,
    output logic        ff_dith_en, ff_dith_2x2, ff_rgb_en, ff_aux_en,
    output logic [FB_AW-1:0] ff_dest_base,
    output logic             ff_dest_valid,
    output logic [FB_AW-1:0] ff_aux_base,
    output logic             ff_aux_valid,
    output logic [10:0] ff_rowpixels,

    // raster launch (§7.2)
    output logic        tri_valid,
    input  logic        tri_ready,
    output tri_params_t tri_params,
    input  logic        tri_done,

    output logic        dispatch_busy
);

  // ----------------------------------------------------------------
  // decode of the FIFO head (CONTRACTS §2, at pop time)
  // ----------------------------------------------------------------
  logic [1:0]  dec_region;
  logic [7:0]  dec_regnum;
  logic [3:0]  dec_chipmask;
  logic [31:0] dec_wdata;
  logic [19:0] dec_lfb_dwoff;
  logic [20:0] dec_tex_dwoff;

  reg_decode u_reg_decode (
      .addr       (cmd_addr),
      .wdata      (cmd_data),
      .swizzle_en (dec_swizzle_en),
      .alias_en   (dec_alias_en),
      .region     (dec_region),
      .regnum     (dec_regnum),
      .chipmask   (dec_chipmask),
      .reg_wdata  (dec_wdata),
      .lfb_dwoff  (dec_lfb_dwoff),
      .tex_dwoff  (dec_tex_dwoff)
  );

  // chipmask kept for trace/debug only (single-TMU config ignores it, §2)
  logic unused_chipmask;
  assign unused_chipmask = &{1'b0, dec_chipmask};

  // ----------------------------------------------------------------
  // shared derived state (effective clip rect, draw buffer, y-origin)
  // ----------------------------------------------------------------
  logic [9:0]       eff_left, eff_right, eff_top, eff_bottom;
  logic [9:0]       yorigin_eff;
  logic [1:0]       drawbuf_idx;
  logic [FB_AW-1:0] dest_base_c;
  logic             dest_valid_c;

  always_comb begin
    eff_left   = fbzmode[0] ? clip_lr[25:16] : 10'd0;
    eff_right  = fbzmode[0] ? clip_lr[9:0]   : width;
    eff_top    = fbzmode[0] ? clip_yy[25:16] : 10'd0;
    eff_bottom = fbzmode[0] ? clip_yy[9:0]   : height;
    // CONTRACTS §9.5: yorigin_eff = (fbiInit3[31:22] != 0) ? that : height-1
    yorigin_eff = (yorigin != 10'd0) ? yorigin : (height - 10'd1);
    // fbzMode[15:14]: 0 = front, 1 = back, else front
    // fbzMode[15:14]: 0=front, 1=back, 2/3 = DROPPED (MAME draw_buffer_indirect)
    drawbuf_idx  = (fbzmode[15:14] == 2'd1) ? backbuf : frontbuf;
    dest_base_c  = rgboffs_w[drawbuf_idx];
    dest_valid_c = rgboffs_valid[drawbuf_idx] & ~fbzmode[15];
  end

  // ----------------------------------------------------------------
  // FSM
  // ----------------------------------------------------------------
  typedef enum logic [3:0] {
    D_IDLE, D_TRI_ADJ, D_TRI_LAUNCH, D_TRI_WAIT,
    D_FF_WAIT, D_LFB_W, D_TEX_W, D_LFB_R, D_RD_RESP
  } dstate_e;

  dstate_e     state_q;
  tri_params_t tri_q;
  logic [3:0]  dxs_q, dys_q;        // subpixel adjust factors, [0,15]
  logic [3:0]  adj_idx_q;           // 0..8 over R,G,B,A,Z,W,S0,T0,W0
  logic        subpix_q;
  logic [31:0] rdata_q;
  logic [19:0] dwoff_q;
  logic [20:0] tex_dwoff_q;
  logic [31:0] wdata_q;
  logic [3:0]  be_q;

  // subpixel multiply-accumulate (raster-algorithm.md §2, 86Box mod-16 form):
  // startP += (dxs*dPdX + dys*dPdY) >> 4, evaluated mod 2^32 / mod 2^64
  logic signed [63:0] adj_dx, adj_dy, adj_start64;
  logic signed [63:0] sum64;
  logic signed [31:0] sum32, new32;
  logic signed [63:0] new64;

  always_comb begin
    unique case (adj_idx_q)
      4'd0:    begin adj_start64 = 64'(tri_q.startr); adj_dx = 64'(tri_q.drdx);  adj_dy = 64'(tri_q.drdy);  end
      4'd1:    begin adj_start64 = 64'(tri_q.startg); adj_dx = 64'(tri_q.dgdx);  adj_dy = 64'(tri_q.dgdy);  end
      4'd2:    begin adj_start64 = 64'(tri_q.startb); adj_dx = 64'(tri_q.dbdx);  adj_dy = 64'(tri_q.dbdy);  end
      4'd3:    begin adj_start64 = 64'(tri_q.starta); adj_dx = 64'(tri_q.dadx);  adj_dy = 64'(tri_q.dady);  end
      4'd4:    begin adj_start64 = 64'(tri_q.startz); adj_dx = 64'(tri_q.dzdx);  adj_dy = 64'(tri_q.dzdy);  end
      4'd5:    begin adj_start64 = tri_q.startw;      adj_dx = tri_q.dwdx;       adj_dy = tri_q.dwdy;       end
      4'd6:    begin adj_start64 = tri_q.s0;          adj_dx = tri_q.ds0dx;      adj_dy = tri_q.ds0dy;      end
      4'd7:    begin adj_start64 = tri_q.t0;          adj_dx = tri_q.dt0dx;      adj_dy = tri_q.dt0dy;      end
      default: begin adj_start64 = tri_q.w0;          adj_dx = tri_q.dw0dx;      adj_dy = tri_q.dw0dy;      end
    endcase
    // products and sum wrap mod 2^64 (everything is 64-bit two's complement)
    sum64 = 64'($signed({1'b0, dxs_q})) * adj_dx
          + 64'($signed({1'b0, dys_q})) * adj_dy;
    // 32-bit parameters: shift and accumulate mod 2^32 (low halves are exact
    // since the multipliers are non-negative and < 16)
    sum32 = $signed(sum64[31:0]);
    new32 = $signed(adj_start64[31:0]) + (sum32 >>> 4);
    new64 = adj_start64 + (sum64 >>> 4);
  end

  // 24->32 sign extension for the RGBA color iterators (gold vsext(.,24);
  // bits [31:24] of the stored register are discarded by design)
  function automatic logic signed [31:0] sx24(input logic [23:0] v);
    return $signed({{8{v[23]}}, v});
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q     <= D_IDLE;
      tri_q       <= '0;
      dxs_q       <= '0;
      dys_q       <= '0;
      adj_idx_q   <= '0;
      subpix_q    <= 1'b0;
      rdata_q     <= '0;
      dwoff_q     <= '0;
      tex_dwoff_q <= '0;
      wdata_q     <= '0;
      be_q        <= '0;
    end else begin
      unique case (state_q)
        D_IDLE: begin
          if (cmd_valid) begin
            if (!cmd_is_write) begin
              // drained read (host_if gated it): execute now
              unique case (dec_region)
                2'b00: begin
                  rdata_q <= rf_rd_data;            // register read (post-alias)
                  state_q <= D_RD_RESP;
                end
                2'b01: begin
                  dwoff_q <= dec_lfb_dwoff;
                  state_q <= D_LFB_R;
                end
                default: begin
                  rdata_q <= 32'hffffffff;          // texture region: write-only
                  state_q <= D_RD_RESP;
                end
              endcase
            end else begin
              unique case (dec_region)
                2'b00: begin
                  unique case (dec_regnum)
                    REG_TRIANGLECMD, REG_FTRIANGLECMD: begin
                      // snapshot everything into tri_params_t (§7.1)
                      tri_q.ax     <= $signed(vtx_ax);
                      tri_q.ay     <= $signed(vtx_ay);
                      tri_q.bx     <= $signed(vtx_bx);
                      tri_q.by     <= $signed(vtx_by);
                      tri_q.cx     <= $signed(vtx_cx);
                      tri_q.cy     <= $signed(vtx_cy);
                      tri_q.sign   <= dec_wdata[31];
                      tri_q.startr <= sx24(it_startr[23:0]);
                      tri_q.startg <= sx24(it_startg[23:0]);
                      tri_q.startb <= sx24(it_startb[23:0]);
                      tri_q.starta <= sx24(it_starta[23:0]);
                      tri_q.drdx   <= sx24(it_drdx[23:0]);
                      tri_q.dgdx   <= sx24(it_dgdx[23:0]);
                      tri_q.dbdx   <= sx24(it_dbdx[23:0]);
                      tri_q.dadx   <= sx24(it_dadx[23:0]);
                      tri_q.drdy   <= sx24(it_drdy[23:0]);
                      tri_q.dgdy   <= sx24(it_dgdy[23:0]);
                      tri_q.dbdy   <= sx24(it_dbdy[23:0]);
                      tri_q.dady   <= sx24(it_dady[23:0]);
                      tri_q.startz <= $signed(it_startz);
                      tri_q.dzdx   <= $signed(it_dzdx);
                      tri_q.dzdy   <= $signed(it_dzdy);
                      tri_q.startw <= sh_w;
                      tri_q.dwdx   <= sh_dwdx;
                      tri_q.dwdy   <= sh_dwdy;
                      tri_q.s0     <= sh_s;
                      tri_q.ds0dx  <= sh_dsdx;
                      tri_q.ds0dy  <= sh_dsdy;
                      tri_q.t0     <= sh_t;
                      tri_q.dt0dx  <= sh_dtdx;
                      tri_q.dt0dy  <= sh_dtdy;
                      tri_q.w0     <= sh_w;
                      tri_q.dw0dx  <= sh_dwdx;
                      tri_q.dw0dy  <= sh_dwdy;
                      tri_q.fbzmode   <= fbzmode;
                      tri_q.fbzcp     <= fbzcp;
                      tri_q.alphamode <= alphamode;
                      tri_q.fogmode   <= fogmode;
                      tri_q.texmode   <= texmode;
                      tri_q.tlod      <= tlod;
                      tri_q.color0    <= color0;
                      tri_q.color1    <= color1;
                      tri_q.zacolor   <= zacolor;
                      tri_q.clip_left   <= eff_left;
                      tri_q.clip_right  <= eff_right;
                      tri_q.clip_top    <= eff_top;
                      tri_q.clip_bottom <= eff_bottom;
                      tri_q.dest_base <= dest_base_c;
                      tri_q.aux_base  <= auxoffs_w;
                      tri_q.aux_valid <= auxoffs_valid;
                      tri_q.rowpixels <= rowpixels;
                      tri_q.yorigin   <= yorigin_eff;
                      // subpixel adjust factors: dxs = (8 - (Ax & 15)) mod 16
                      dxs_q     <= 4'd8 - vtx_ax[3:0];
                      dys_q     <= 4'd8 - vtx_ay[3:0];
                      subpix_q  <= fbzcp[26];
                      adj_idx_q <= 4'd0;
                      // no destination buffer -> drop the triangle (gold)
                      if (dest_valid_c)
                        state_q <= fbzcp[26] ? D_TRI_ADJ : D_TRI_LAUNCH;
                    end
                    REG_FASTFILLCMD:   state_q <= D_FF_WAIT;
                    REG_SWAPBUFFERCMD: ;       // rf_swap pulses below
                    REG_NOPCMD:        ;       // accept, no-op
                    default:           ;       // plain register write (rf_wr_en)
                  endcase
                end
                2'b01: begin
                  dwoff_q <= dec_lfb_dwoff;
                  wdata_q <= cmd_data;             // raw: lfb_unit swizzles
                  be_q    <= cmd_be;
                  state_q <= D_LFB_W;
                end
                default: begin
                  tex_dwoff_q <= dec_tex_dwoff;
                  wdata_q     <= cmd_data;         // raw: tex_dl swizzles (tLOD)
                  state_q     <= D_TEX_W;
                end
              endcase
            end
          end
        end

        D_TRI_ADJ: begin
          unique case (adj_idx_q)
            4'd0:    tri_q.startr <= new32;
            4'd1:    tri_q.startg <= new32;
            4'd2:    tri_q.startb <= new32;
            4'd3:    tri_q.starta <= new32;
            4'd4:    tri_q.startz <= new32;
            4'd5:    tri_q.startw <= new64;
            4'd6:    tri_q.s0     <= new64;
            4'd7:    tri_q.t0     <= new64;
            default: tri_q.w0     <= new64;
          endcase
          if (adj_idx_q == 4'd8)
            state_q <= D_TRI_LAUNCH;
          else
            adj_idx_q <= adj_idx_q + 4'd1;
        end

        D_TRI_LAUNCH: if (tri_ready) state_q <= D_TRI_WAIT;
        D_TRI_WAIT:   if (tri_done)  state_q <= D_IDLE;
        D_FF_WAIT:    if (ff_done)   state_q <= D_IDLE;
        D_LFB_W:      if (lfb_wr_done) state_q <= D_IDLE;
        D_TEX_W:      if (tex_wr_done) state_q <= D_IDLE;
        D_LFB_R: begin
          if (lfb_rd_done) begin
            rdata_q <= lfb_rd_data;
            state_q <= D_RD_RESP;
          end
        end
        D_RD_RESP: state_q <= D_IDLE;
        default:   state_q <= D_IDLE;
      endcase
    end
  end

  // ----------------------------------------------------------------
  // outputs
  // ----------------------------------------------------------------
  logic in_idle, popping;
  always_comb begin
    in_idle = (state_q == D_IDLE);
    popping = in_idle & cmd_valid;
    cmd_pop = popping;

    // regfile
    rf_rd_regnum = dec_regnum;
    rf_wr_en     = popping & cmd_is_write & (dec_region == 2'b00)
                 & (dec_regnum != REG_TRIANGLECMD)
                 & (dec_regnum != REG_FTRIANGLECMD)
                 & (dec_regnum != REG_FASTFILLCMD)
                 & (dec_regnum != REG_SWAPBUFFERCMD)
                 & (dec_regnum != REG_NOPCMD);
    rf_wr_regnum = dec_regnum;
    rf_wr_data   = dec_wdata;
    rf_swap      = popping & cmd_is_write & (dec_region == 2'b00)
                 & (dec_regnum == REG_SWAPBUFFERCMD);

    // fastfill launch (params sampled by fastfill while ff_go is high)
    ff_go          = popping & cmd_is_write & (dec_region == 2'b00)
                   & (dec_regnum == REG_FASTFILLCMD);
    // fastfill uses the clip-rect REGISTERS unconditionally (MAME
    // reg_fastfill_w), unlike the triangle path's fbzMode[0]-gated rect
    ff_clip_left   = clip_lr[25:16];
    ff_clip_right  = clip_lr[9:0];
    ff_clip_top    = clip_yy[25:16];
    ff_clip_bottom = clip_yy[9:0];
    ff_color1      = color1;
    ff_zfill       = zacolor[15:0];
    ff_dith_en     = fbzmode[8];
    ff_dith_2x2    = fbzmode[11];
    ff_rgb_en      = fbzmode[9];
    ff_aux_en      = fbzmode[10];
    ff_dest_base   = dest_base_c;
    ff_dest_valid  = dest_valid_c;
    ff_aux_base    = auxoffs_w;
    ff_aux_valid   = auxoffs_valid;
    ff_rowpixels   = rowpixels;

    // lfb / tex engines
    lfb_wr_valid = (state_q == D_LFB_W);
    lfb_wr_dwoff = dwoff_q;
    lfb_wr_data  = wdata_q;
    lfb_wr_be    = be_q;
    lfb_rd_valid = (state_q == D_LFB_R);
    lfb_rd_dwoff = dwoff_q;
    tex_wr_valid = (state_q == D_TEX_W);
    tex_wr_dwoff = tex_dwoff_q;
    tex_wr_data  = wdata_q;

    // triangle launch
    tri_valid  = (state_q == D_TRI_LAUNCH);
    tri_params = tri_q;

    // read response
    rd_resp_valid = (state_q == D_RD_RESP);
    rd_resp_data  = rdata_q;

    dispatch_busy = ~in_idle;
  end

  // subpix_q is latched for clarity/debug; the launch path keys off
  // fbzcp[26] at snapshot time directly. Clip registers only carry 10-bit
  // fields; RGBA iterator registers are 24-bit sign-extended at launch.
  logic unused_misc;
  assign unused_misc = &{1'b0, subpix_q,
                         clip_lr[31:26], clip_lr[15:10],
                         clip_yy[31:26], clip_yy[15:10],
                         it_startr[31:24], it_startg[31:24], it_startb[31:24],
                         it_starta[31:24], it_drdx[31:24], it_dgdx[31:24],
                         it_dbdx[31:24], it_dadx[31:24], it_drdy[31:24],
                         it_dgdy[31:24], it_dbdy[31:24], it_dady[31:24]};

endmodule
