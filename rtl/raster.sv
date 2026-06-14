// raster.sv — [raster agent] triangle walker (CONTRACTS §5/§7.2, M2).
//
// Implements the NORMATIVE integer edge-walk of docs/raster-algorithm.md
// bit-for-bit against model/voodoo_gold.c raster_triangle():
//   - edge slopes: trunc32((sext64(dx)<<16)/dy), 0 when dy==0 (C trunc-toward-
//     zero semantics; gold edge_slope(), 86box vid_voodoo_render.c
//     voodoo_triangle() 1446-1596) — one shared sequential restoring divider.
//   - ystart0=(Ay+7)>>>4, yend0=(Cy+7)>>>4 (excl), pA=(Ax+7)>>>4; y-clip to
//     the effective clip rect (raster-algorithm.md §2, CONTRACTS §9.9).
//   - per row: ys=(y<<4)+8; xMaj on AC, xMin on AB while ys<By else BC; the
//     products dxEdge*(ys-Vy) are taken full-width then >>>4 and the sums are
//     truncated to 32 bits; -0x10000 pullback on the trailing (right) edge
//     only; both ends rounded with +0x7000 then >>>16; X-clip; inclusive walk
//     from xMaj in the sign-determined direction (raster-algorithm.md §4).
//   - iterators (r,g,b,a,z mod 2^32; w,s0,t0,w0 mod 2^64): incremental row/
//     pixel accumulators that are bit-identical to the absolute formula
//     P(x,y)=startP+(x-pA)*dPdX+(y-ystart0)*dPdY of raster-algorithm.md §3
//     (two's-complement wrap makes repeated addition equal multiplication).
//
// Pixel emission uses a 1-deep hold stage so that px_last can be asserted on
// the true final pixel (the walker only releases a held pixel once a younger
// one exists, or at end-of-triangle with px_last=1).
//
// Zero-pixel triangles: the §7.2 wiring has no dedicated "no pixels" signal
// and cmd_dispatch waits for pixel_pipe's tri_done, so a triangle that covers
// nothing emits ONE dummy beat with px_last=1 and (px_x,px_y)=(1023,1023),
// which is provably outside any reachable clip rect (clip_right/bottom are
// 10-bit exclusive bounds, so a real pixel never has x or y == 1023); the
// pixel pipe discards out-of-clip-rect pixels without side effects and still
// pulses tri_done. Flagged in the integration report.
module raster
  import voodoo_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,

    // dispatch -> raster (§7.2)
    input  logic        tri_valid,
    output logic        tri_ready,
    input  tri_params_t tri_params,

    // raster -> pixel_pipe (§7.2)
    output logic        px_valid,
    input  logic        px_ready,
    output logic        px_last,
    output logic [9:0]  px_x,
    output logic [9:0]  px_y,
    output logic signed [31:0] px_r,
    output logic signed [31:0] px_g,
    output logic signed [31:0] px_b,
    output logic signed [31:0] px_a,
    output logic signed [31:0] px_z,
    output logic signed [63:0] px_w,
    output logic signed [63:0] px_s0,
    output logic signed [63:0] px_t0,
    output logic signed [63:0] px_w0
);

  // ----------------------------------------------------------------
  // FSM
  // ----------------------------------------------------------------
  typedef enum logic [3:0] {
    R_IDLE,       // wait for tri_valid
    R_DIV_INIT,   // load divider for edge div_idx (or skip if dy==0)
    R_DIV_RUN,    // 32 restoring-division iterations
    R_DIV_STORE,  // sign-correct and store slope
    R_SETUP,      // ystart/yend/pA; bail if no rows
    R_ROWINIT,    // rowP[ch] = startP[ch] + (ystart-ystart0)*dPdY[ch]
    R_XMAJ,       // xmaj for current row (shared multiplier)
    R_XMIN,       // xmin for current row (shared multiplier)
    R_SPAN,       // round/pullback/clip/empty-test
    R_SPANINIT,   // pixP[ch] = rowP[ch] + (first-pA)*dPdX[ch]
    R_WALK,       // emit pixels first..last inclusive
    R_NEXTROW,    // y++, rowP += dPdY
    R_FLUSH,      // release held final pixel (px_last=1) or dummy beat
    R_DRAIN       // wait for the last beat to be accepted
  } rstate_e;

  rstate_e state_q;

  // ----------------------------------------------------------------
  // latched triangle parameters
  // ----------------------------------------------------------------
  logic signed [15:0] ax_q, ay_q, bx_q, by_q, cx_q, cy_q;
  logic               sign_q;
  logic [9:0]         cl_q, cr_q, ct_q, cb_q;

  // iterator channels 0..8 = r,g,b,a,z,w,s0,t0,w0; 32-bit channels are kept
  // sign-extended in 64 bits (low-32 truncation of mod-2^64 arithmetic is
  // exactly mod-2^32 arithmetic).
  logic signed [63:0] ch_start [9];
  logic signed [63:0] ch_dx    [9];
  logic signed [63:0] ch_dy    [9];

  // ----------------------------------------------------------------
  // shared sequential divider (slope = trunc32((sext64(dx)<<16)/dy))
  // gold edge_slope(); C trunc-toward-zero = floor on magnitudes with the
  // result negated when operand signs differ (division here is exact).
  // ----------------------------------------------------------------
  logic [1:0]  div_idx_q;          // 0=AB, 1=AC, 2=BC
  logic        div_neg_q;
  logic [31:0] div_dvd_q;          // |dx| << 16 (|dx| <= 65535)
  logic [15:0] div_dvs_q;          // |dy|       (|dy| <= 65535, != 0)
  logic [15:0] div_rem_q;
  logic [31:0] div_quot_q;
  logic [5:0]  div_cnt_q;

  logic signed [31:0] dxab_q, dxac_q, dxbc_q;

  logic signed [16:0] div_num, div_den;
  always_comb begin
    unique case (div_idx_q)
      2'd0:    begin div_num = 17'({bx_q[15], bx_q}) - 17'({ax_q[15], ax_q});
                     div_den = 17'({by_q[15], by_q}) - 17'({ay_q[15], ay_q}); end
      2'd1:    begin div_num = 17'({cx_q[15], cx_q}) - 17'({ax_q[15], ax_q});
                     div_den = 17'({cy_q[15], cy_q}) - 17'({ay_q[15], ay_q}); end
      default: begin div_num = 17'({cx_q[15], cx_q}) - 17'({bx_q[15], bx_q});
                     div_den = 17'({cy_q[15], cy_q}) - 17'({by_q[15], by_q}); end
    endcase
  end

  // |v| of a 17-bit signed difference of two s16 values (range +/-65535, so
  // the magnitude always fits 16 bits and 16-bit negation is exact)
  function automatic logic [15:0] mag17(input logic signed [16:0] v);
    return v[16] ? (16'h0000 - v[15:0]) : v[15:0];
  endfunction

  // one restoring-division step (16-bit remainder is enough: rem < |dy|)
  logic [16:0] div_trial;
  logic        div_qbit;
  always_comb begin
    div_trial = {div_rem_q, div_dvd_q[31]};
    div_qbit  = (div_trial >= {1'b0, div_dvs_q});
  end

  // ----------------------------------------------------------------
  // setup / per-row scalars (32-bit signed working registers)
  // ----------------------------------------------------------------
  logic signed [31:0] pa_q;
  logic signed [31:0] yend_q;
  logic signed [31:0] y_q;
  logic signed [31:0] dy0_q, dx0_q;
  logic signed [31:0] first_q, last_q;
  logic signed [31:0] x_q;
  logic [31:0]        xmaj_q, xmin_q;
  logic [3:0]         ch_q;

  // setup combinational values (raster-algorithm.md §2)
  logic signed [31:0] ystart0_c, yend0_c, ystart_c, yend_c;
  logic signed [31:0] cl32, cr32, ct32, cb32;
  always_comb begin
    cl32 = $signed({22'b0, cl_q});
    cr32 = $signed({22'b0, cr_q});
    ct32 = $signed({22'b0, ct_q});
    cb32 = $signed({22'b0, cb_q});
    ystart0_c = (32'(ay_q) + 32'sd7) >>> 4;
    yend0_c   = (32'(cy_q) + 32'sd7) >>> 4;
    ystart_c  = (ystart0_c > ct32) ? ystart0_c : ct32;
    yend_c    = (yend0_c < cb32) ? yend0_c : cb32;
  end

  // row center in 12.4 (raster-algorithm.md §4)
  logic signed [31:0] ys_c;
  assign ys_c = (y_q <<< 4) + 32'sd8;

  // minor edge select: AB while ys < By, else BC (ties use BC)
  logic minor_is_ab;
  assign minor_is_ab = (ys_c < 32'(by_q));

  // ----------------------------------------------------------------
  // shared 64x64->64 multiplier (mod-2^64 product)
  // ----------------------------------------------------------------
  logic signed [63:0] mul_a, mul_b, mul_p;
  always_comb begin
    unique case (state_q)
      R_ROWINIT: begin mul_a = ch_dy[ch_q]; mul_b = 64'(dy0_q); end
      R_XMAJ:    begin mul_a = 64'(dxac_q); mul_b = 64'(ys_c - 32'(ay_q)); end
      R_XMIN: begin
        if (minor_is_ab) begin
          mul_a = 64'(dxab_q); mul_b = 64'(ys_c - 32'(ay_q));
        end else begin
          mul_a = 64'(dxbc_q); mul_b = 64'(ys_c - 32'(by_q));
        end
      end
      R_SPANINIT: begin mul_a = ch_dx[ch_q]; mul_b = 64'(dx0_q); end
      default:    begin mul_a = '0; mul_b = '0; end
    endcase
  end
  assign mul_p = mul_a * mul_b;   // SV: 64-bit operands -> mod-2^64 product

  // edge intercept: (Vx<<12) + asr4(slope * (ys - Vy)), truncated to 32 bits
  // (gold raster_triangle, raster-algorithm.md §4: 49-bit product, >>>4)
  logic [31:0] edge_base, edge_acc;
  always_comb begin
    edge_base = (state_q == R_XMIN && !minor_is_ab)
              ? (32'(bx_q) <<< 12)
              : (32'(ax_q) <<< 12);
    edge_acc  = edge_base + 32'((mul_p >>> 4));
  end

  // span endpoints (raster-algorithm.md §4: +0x7000 round bias, -0x10000
  // pullback on the trailing/right edge only, then clip and empty-test)
  logic signed [31:0] rawfirst_c, rawlast_c, first_c, last_c;
  logic               empty_c;
  always_comb begin
    if (!sign_q) begin                 // AC is LEFT edge, walk +x
      rawfirst_c = $signed(xmaj_q + 32'h0000_7000) >>> 16;
      rawlast_c  = $signed(xmin_q + 32'hffff_7000) >>> 16;   // -0x10000+0x7000
      first_c    = (rawfirst_c < cl32) ? cl32 : rawfirst_c;
      last_c     = (rawlast_c >= cr32) ? (cr32 - 32'sd1) : rawlast_c;
      empty_c    = (last_c < first_c);
    end else begin                     // AC is RIGHT edge, walk -x
      rawfirst_c = $signed(xmaj_q + 32'hffff_7000) >>> 16;
      rawlast_c  = $signed(xmin_q + 32'h0000_7000) >>> 16;
      first_c    = (rawfirst_c >= cr32) ? (cr32 - 32'sd1) : rawfirst_c;
      last_c     = (rawlast_c < cl32) ? cl32 : rawlast_c;
      empty_c    = (last_c > first_c);
    end
  end

  // ----------------------------------------------------------------
  // iterator accumulators
  // ----------------------------------------------------------------
  logic signed [63:0] rowp [9];
  logic signed [63:0] pixp [9];

  // ----------------------------------------------------------------
  // 1-deep hold stage + registered output beat
  // ----------------------------------------------------------------
  logic               hold_valid_q;
  logic [9:0]         hold_x_q, hold_y_q;
  logic signed [63:0] hold_v [9];

  logic out_free, can_produce;
  assign out_free    = ~px_valid | px_ready;
  assign can_produce = ~hold_valid_q | out_free;

  assign tri_ready = (state_q == R_IDLE);

  // ----------------------------------------------------------------
  // main sequential process
  // ----------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q      <= R_IDLE;
      ax_q <= '0; ay_q <= '0; bx_q <= '0; by_q <= '0; cx_q <= '0; cy_q <= '0;
      sign_q       <= 1'b0;
      cl_q <= '0; cr_q <= '0; ct_q <= '0; cb_q <= '0;
      div_idx_q    <= '0;
      div_neg_q    <= 1'b0;
      div_dvd_q    <= '0;
      div_dvs_q    <= '0;
      div_rem_q    <= '0;
      div_quot_q   <= '0;
      div_cnt_q    <= '0;
      dxab_q <= '0; dxac_q <= '0; dxbc_q <= '0;
      pa_q <= '0; yend_q <= '0;
      y_q <= '0; dy0_q <= '0; dx0_q <= '0;
      first_q <= '0; last_q <= '0; x_q <= '0;
      xmaj_q <= '0; xmin_q <= '0;
      ch_q         <= '0;
      hold_valid_q <= 1'b0;
      hold_x_q     <= '0;
      hold_y_q     <= '0;
      px_valid     <= 1'b0;
      px_last      <= 1'b0;
      px_x <= '0; px_y <= '0;
      px_r <= '0; px_g <= '0; px_b <= '0; px_a <= '0; px_z <= '0;
      px_w <= '0; px_s0 <= '0; px_t0 <= '0; px_w0 <= '0;
      for (int i = 0; i < 9; i++) begin
        ch_start[i] <= '0;
        ch_dx[i]    <= '0;
        ch_dy[i]    <= '0;
        rowp[i]     <= '0;
        pixp[i]     <= '0;
        hold_v[i]   <= '0;
      end
    end else begin
      // default: retire an accepted output beat
      if (px_valid && px_ready)
        px_valid <= 1'b0;

      unique case (state_q)
        // ------------------------------------------------------------
        R_IDLE: begin
          if (tri_valid) begin
            ax_q   <= tri_params.ax;
            ay_q   <= tri_params.ay;
            bx_q   <= tri_params.bx;
            by_q   <= tri_params.by;
            cx_q   <= tri_params.cx;
            cy_q   <= tri_params.cy;
            sign_q <= tri_params.sign;
            cl_q   <= tri_params.clip_left;
            cr_q   <= tri_params.clip_right;
            ct_q   <= tri_params.clip_top;
            cb_q   <= tri_params.clip_bottom;
            ch_start[0] <= 64'(tri_params.startr);
            ch_start[1] <= 64'(tri_params.startg);
            ch_start[2] <= 64'(tri_params.startb);
            ch_start[3] <= 64'(tri_params.starta);
            ch_start[4] <= 64'(tri_params.startz);
            ch_start[5] <= tri_params.startw;
            ch_start[6] <= tri_params.s0;
            ch_start[7] <= tri_params.t0;
            ch_start[8] <= tri_params.w0;
            ch_dx[0] <= 64'(tri_params.drdx);
            ch_dx[1] <= 64'(tri_params.dgdx);
            ch_dx[2] <= 64'(tri_params.dbdx);
            ch_dx[3] <= 64'(tri_params.dadx);
            ch_dx[4] <= 64'(tri_params.dzdx);
            ch_dx[5] <= tri_params.dwdx;
            ch_dx[6] <= tri_params.ds0dx;
            ch_dx[7] <= tri_params.dt0dx;
            ch_dx[8] <= tri_params.dw0dx;
            ch_dy[0] <= 64'(tri_params.drdy);
            ch_dy[1] <= 64'(tri_params.dgdy);
            ch_dy[2] <= 64'(tri_params.dbdy);
            ch_dy[3] <= 64'(tri_params.dady);
            ch_dy[4] <= 64'(tri_params.dzdy);
            ch_dy[5] <= tri_params.dwdy;
            ch_dy[6] <= tri_params.ds0dy;
            ch_dy[7] <= tri_params.dt0dy;
            ch_dy[8] <= tri_params.dw0dy;
            hold_valid_q <= 1'b0;
            div_idx_q    <= 2'd0;
            state_q      <= R_DIV_INIT;
          end
        end

        // ------------------------------------------------------------
        R_DIV_INIT: begin
          if (div_den == 17'sd0) begin
            // dy == 0 -> slope 0 (gold edge_slope)
            unique case (div_idx_q)
              2'd0:    dxab_q <= 32'sd0;
              2'd1:    dxac_q <= 32'sd0;
              default: dxbc_q <= 32'sd0;
            endcase
            if (div_idx_q == 2'd2)
              state_q <= R_SETUP;
            else
              div_idx_q <= div_idx_q + 2'd1;
          end else begin
            div_neg_q  <= div_num[16] ^ div_den[16];
            div_dvd_q  <= {mag17(div_num), 16'b0};
            div_dvs_q  <= mag17(div_den);
            div_rem_q  <= '0;
            div_quot_q <= '0;
            div_cnt_q  <= 6'd32;
            state_q    <= R_DIV_RUN;
          end
        end

        R_DIV_RUN: begin
          if (div_qbit)
            div_rem_q <= 16'(div_trial - {1'b0, div_dvs_q});
          else
            div_rem_q <= div_trial[15:0];
          div_quot_q <= {div_quot_q[30:0], div_qbit};
          div_dvd_q  <= {div_dvd_q[30:0], 1'b0};
          div_cnt_q  <= div_cnt_q - 6'd1;
          if (div_cnt_q == 6'd1)
            state_q <= R_DIV_STORE;
        end

        R_DIV_STORE: begin
          // negate the magnitude quotient if operand signs differed; the
          // 32-bit wrap equals C's trunc32 of the signed 64-bit quotient
          unique case (div_idx_q)
            2'd0:    dxab_q <= $signed(div_neg_q ? (32'h0 - div_quot_q) : div_quot_q);
            2'd1:    dxac_q <= $signed(div_neg_q ? (32'h0 - div_quot_q) : div_quot_q);
            default: dxbc_q <= $signed(div_neg_q ? (32'h0 - div_quot_q) : div_quot_q);
          endcase
          if (div_idx_q == 2'd2)
            state_q <= R_SETUP;
          else begin
            div_idx_q <= div_idx_q + 2'd1;
            state_q   <= R_DIV_INIT;
          end
        end

        // ------------------------------------------------------------
        R_SETUP: begin
          yend_q    <= yend_c;
          pa_q      <= (32'(ax_q) + 32'sd7) >>> 4;
          y_q       <= ystart_c;
          dy0_q     <= ystart_c - ystart0_c;
          ch_q      <= 4'd0;
          if (ystart_c >= yend_c)
            state_q <= R_FLUSH;          // no candidate rows at all
          else
            state_q <= R_ROWINIT;
        end

        R_ROWINIT: begin
          // rowP = startP + (ystart-ystart0)*dPdY  (mod 2^32 / 2^64)
          rowp[ch_q] <= ch_start[ch_q] + mul_p;
          if (ch_q == 4'd8) begin
            ch_q    <= 4'd0;
            state_q <= R_XMAJ;
          end else
            ch_q <= ch_q + 4'd1;
        end

        // ------------------------------------------------------------
        R_XMAJ: begin
          xmaj_q  <= edge_acc;
          state_q <= R_XMIN;
        end

        R_XMIN: begin
          xmin_q  <= edge_acc;
          state_q <= R_SPAN;
        end

        R_SPAN: begin
          if (empty_c)
            state_q <= R_NEXTROW;
          else begin
            first_q <= first_c;
            last_q  <= last_c;
            dx0_q   <= first_c - pa_q;
            ch_q    <= 4'd0;
            state_q <= R_SPANINIT;
          end
        end

        R_SPANINIT: begin
          // pixP = rowP + (first-pA)*dPdX  (mod 2^32 / 2^64)
          pixp[ch_q] <= rowp[ch_q] + mul_p;
          if (ch_q == 4'd8) begin
            ch_q    <= 4'd0;
            x_q     <= first_q;
            state_q <= R_WALK;
          end else
            ch_q <= ch_q + 4'd1;
        end

        // ------------------------------------------------------------
        R_WALK: begin
          if (can_produce) begin
            if (hold_valid_q) begin
              // release the held (now provably non-final) pixel
              px_valid <= 1'b1;
              px_last  <= 1'b0;
              px_x     <= hold_x_q;
              px_y     <= hold_y_q;
              px_r     <= hold_v[0][31:0];
              px_g     <= hold_v[1][31:0];
              px_b     <= hold_v[2][31:0];
              px_a     <= hold_v[3][31:0];
              px_z     <= hold_v[4][31:0];
              px_w     <= hold_v[5];
              px_s0    <= hold_v[6];
              px_t0    <= hold_v[7];
              px_w0    <= hold_v[8];
            end
            hold_valid_q <= 1'b1;
            hold_x_q     <= x_q[9:0];
            hold_y_q     <= y_q[9:0];
            for (int i = 0; i < 9; i++)
              hold_v[i] <= pixp[i];
            if (x_q == last_q)
              state_q <= R_NEXTROW;
            else begin
              x_q <= sign_q ? (x_q - 32'sd1) : (x_q + 32'sd1);
              for (int i = 0; i < 9; i++)
                pixp[i] <= sign_q ? (pixp[i] - ch_dx[i]) : (pixp[i] + ch_dx[i]);
            end
          end
        end

        R_NEXTROW: begin
          for (int i = 0; i < 9; i++)
            rowp[i] <= rowp[i] + ch_dy[i];
          y_q <= y_q + 32'sd1;
          if (y_q + 32'sd1 >= yend_q)
            state_q <= R_FLUSH;
          else
            state_q <= R_XMAJ;
        end

        // ------------------------------------------------------------
        R_FLUSH: begin
          if (out_free) begin
            px_valid <= 1'b1;
            px_last  <= 1'b1;
            if (hold_valid_q) begin
              hold_valid_q <= 1'b0;
              px_x  <= hold_x_q;
              px_y  <= hold_y_q;
              px_r  <= hold_v[0][31:0];
              px_g  <= hold_v[1][31:0];
              px_b  <= hold_v[2][31:0];
              px_a  <= hold_v[3][31:0];
              px_z  <= hold_v[4][31:0];
              px_w  <= hold_v[5];
              px_s0 <= hold_v[6];
              px_t0 <= hold_v[7];
              px_w0 <= hold_v[8];
            end else begin
              // zero-pixel triangle: out-of-clip dummy beat (see header)
              px_x  <= 10'h3ff;
              px_y  <= 10'h3ff;
              px_r  <= '0;
              px_g  <= '0;
              px_b  <= '0;
              px_a  <= '0;
              px_z  <= '0;
              px_w  <= '0;
              px_s0 <= '0;
              px_t0 <= '0;
              px_w0 <= '0;
            end
            state_q <= R_DRAIN;
          end
        end

        R_DRAIN: begin
          if (px_valid && px_ready) begin
            px_valid <= 1'b0;
            state_q  <= R_IDLE;
          end
        end

        default: state_q <= R_IDLE;
      endcase
    end
  end

  // tri_params fields consumed by the pixel pipe only (raster passes the
  // iterator stream; the pipe latches its own copy of tri_params per §7.2)
  logic unused_tp;
  assign unused_tp = &{1'b0,
                       tri_params.fbzmode, tri_params.fbzcp,
                       tri_params.alphamode, tri_params.fogmode,
                       tri_params.texmode, tri_params.tlod,
                       tri_params.color0, tri_params.color1,
                       tri_params.zacolor, tri_params.dest_base,
                       tri_params.stipple, tri_params.chromakey,
                       tri_params.fogcolor,
                       tri_params.aux_base, tri_params.aux_valid,
                       tri_params.rowpixels, tri_params.yorigin};

endmodule
