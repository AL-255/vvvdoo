// raster.sv — [raster agent] triangle walker (CONTRACTS §5/§7.2, M2/M3).
//
// FLOAT coverage port: mirrors model/voodoo_gold.c raster_triangle() bit-for-
// bit using Verilator `real` (IEEE-754 double == C double). The triangle
// coverage (which scanlines, and the [left,right) span on each) now follows
// MAME's floating-point poly rule exactly:
//   - float verts vx = real'(coord) * (1.0/16.0) from the 12.4 s16 coords;
//   - stable sort the 3 (vx,vy) by vy ascending into (v1,v2,v3);
//   - edge slopes dxdy13/dxdy12/dxdy23 = (dx)/(dy) in `real` (0.0 if dy==0);
//   - iy1/iy3 = round_coordinate(v1y/v3y), y-clipped to [ct,cb);
//   - per scanline curscan: fully = curscan+0.5; startx on the long edge
//     v1->v3, stopx on v1->v2 (fully<v2y) else v2->v3; round_coordinate both
//     (ties .5 round DOWN), swap so left<=right, clip to [cl,cr), EXCLUSIVE
//     right, draw [left,right).
//   - round_coordinate(v): f=$floor(v); $rtoi(f) + ((v-f)>0.5 ? 1 : 0).
//
// `real` is SIMULATION-ONLY (not synthesizable). This is the accepted trade
// for bit-exactness with the float golden model; the coverage math here is a
// behavioral model, while the per-pixel INTEGER iterator accumulators (rowp/
// pixp, mod 2^32 / 2^64) are unchanged and synthesizable.
//
// The iterator ORIGIN is now the ORIGINAL vertex A, arithmetic-floored:
//   ox = $signed(ax) >>> 4, oy = $signed(ay) >>> 4
// matching gold's ox=asr32(ax,4), oy=asr32(ay,4). The per-pixel value
//   P(x,y) = startP + (x-ox)*dPdX + (y-oy)*dPdY
// is built incrementally (row accumulator seeded at curscan, pixel accumulator
// seeded at left); two's-complement wrap makes repeated addition equal the
// absolute multiply form gold uses.
//
// The triangleCMD sign bit is IGNORED (winding handled by the start/stop swap),
// matching gold. Subpixel start adjustment (fbzcp bit26) is applied upstream in
// cmd_dispatch before launch.
//
// Zero-pixel triangles: the §7.2 wiring has no dedicated "no pixels" signal and
// cmd_dispatch waits for pixel_pipe's tri_done, so a triangle covering nothing
// emits ONE dummy beat with px_last=1 and (px_x,px_y)=(1023,1023), provably
// outside any reachable clip rect; the pixel pipe discards it and still pulses
// tri_done.
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

  // round_coordinate(v): MAME poly.h round-to-nearest, ties (.5) round DOWN.
  // f=$floor(v); $rtoi(f) is exact for integer-valued reals.
  function automatic int round_coordinate(input real v);
    real f;
    f = $floor(v);
    return $rtoi(f) + (((v - f) > 0.5) ? 1 : 0);
  endfunction

  // ----------------------------------------------------------------
  // FSM
  // ----------------------------------------------------------------
  typedef enum logic [3:0] {
    R_IDLE,       // wait for tri_valid
    R_SETUP,      // compute float coverage scalars; bail if no rows
    R_ROWINIT,    // rowP[ch] = startP[ch] + (curscan-oy)*dPdY
    R_SPAN,       // float startx/stopx -> [left,right); empty test
    R_SPANINIT,   // pixP[ch] = rowP[ch] + (left-ox)*dPdX
    R_WALK,       // emit pixels left..right-1 inclusive
    R_NEXTROW,    // curscan++, rowP += dPdY
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
  // FLOAT coverage scalars (sim-only `real`). Latched at R_SETUP from the
  // sorted float verts; used combinationally per scanline.
  // ----------------------------------------------------------------
  // v1,v2 needed per-scanline; v3 only feeds the (precomputed) slopes.
  real v1x_q, v1y_q, v2x_q, v2y_q;
  real dxdy13_q, dxdy12_q, dxdy23_q;

  // ----------------------------------------------------------------
  // setup / per-row scalars (32-bit signed working registers)
  // ----------------------------------------------------------------
  logic signed [31:0] ox_q;           // iterator x-origin = floor(ax/16)
  logic signed [31:0] yend_q;         // iy3 (clipped), exclusive
  logic signed [31:0] y_q;            // current curscan
  logic signed [31:0] dy0_q, dx0_q;   // (curscan-oy), (left-ox)
  logic signed [31:0] first_q, last_q;
  logic signed [31:0] x_q;
  logic [3:0]         ch_q;

  // 32-bit clip values
  logic signed [31:0] cl32, cr32, ct32, cb32;
  always_comb begin
    cl32 = $signed({22'b0, cl_q});
    cr32 = $signed({22'b0, cr_q});
    ct32 = $signed({22'b0, ct_q});
    cb32 = $signed({22'b0, cb_q});
  end

  // ----------------------------------------------------------------
  // shared 64x64->64 multiplier (mod-2^64 product) for the integer
  // iterator seeding: rowP and pixP origins.
  // ----------------------------------------------------------------
  logic signed [63:0] mul_a, mul_b, mul_p;
  always_comb begin
    unique case (state_q)
      R_ROWINIT:  begin mul_a = ch_dy[ch_q]; mul_b = 64'(dy0_q); end
      R_SPANINIT: begin mul_a = ch_dx[ch_q]; mul_b = 64'(dx0_q); end
      default:    begin mul_a = '0; mul_b = '0; end
    endcase
  end
  assign mul_p = mul_a * mul_b;   // SV: 64-bit operands -> mod-2^64 product

  // ----------------------------------------------------------------
  // per-scanline float span (combinational, gold raster_triangle loop body)
  // ----------------------------------------------------------------
  real fully_c, startx_c, stopx_c;
  int  istartx_c, istopx_c, ilo_c, ihi_c;
  logic signed [31:0] first_c, last_c;
  logic               empty_c;
  always_comb begin
    fully_c  = real'(y_q) + 0.5;
    startx_c = v1x_q + (fully_c - v1y_q) * dxdy13_q;
    stopx_c  = (fully_c < v2y_q) ? (v1x_q + (fully_c - v1y_q) * dxdy12_q)
                                 : (v2x_q + (fully_c - v2y_q) * dxdy23_q);
    istartx_c = round_coordinate(startx_c);
    istopx_c  = round_coordinate(stopx_c);
    // swap so lo<=hi (winding-agnostic)
    ilo_c = (istartx_c > istopx_c) ? istopx_c : istartx_c;
    ihi_c = (istartx_c > istopx_c) ? istartx_c : istopx_c;
    // clip to [cl, cr); right EXCLUSIVE
    if ($signed(ilo_c) < cl32) ilo_c = cl32;
    if ($signed(ihi_c) > cr32) ihi_c = cr32;
    first_c = $signed(ilo_c);
    last_c  = $signed(ihi_c) - 32'sd1;     // inclusive walk forward
    empty_c = ($signed(ilo_c) >= $signed(ihi_c));
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
      v1x_q <= 0.0; v1y_q <= 0.0; v2x_q <= 0.0; v2y_q <= 0.0;
      dxdy13_q <= 0.0; dxdy12_q <= 0.0; dxdy23_q <= 0.0;
      ox_q <= '0; yend_q <= '0;
      y_q <= '0; dy0_q <= '0; dx0_q <= '0;
      first_q <= '0; last_q <= '0; x_q <= '0;
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
            state_q      <= R_SETUP;
          end
        end

        // ------------------------------------------------------------
        // R_SETUP: build float verts, stable-sort by vy ascending, compute
        // edge slopes, iy1/iy3, origin floor; seed the scanline loop.
        R_SETUP: begin
          // float verts from 12.4 coords (/16) — same expressions as gold
          real ax_f, ay_f, bx_f, by_f, cx_f, cy_f;
          real s1x, s1y, s2x, s2y, s3x, s3y;   // sorted v1,v2,v3
          real t;
          real d13, d12, d23;
          int  iy1, iy3;
          ax_f = real'($signed(ax_q)) * (1.0 / 16.0);
          ay_f = real'($signed(ay_q)) * (1.0 / 16.0);
          bx_f = real'($signed(bx_q)) * (1.0 / 16.0);
          by_f = real'($signed(by_q)) * (1.0 / 16.0);
          cx_f = real'($signed(cx_q)) * (1.0 / 16.0);
          cy_f = real'($signed(cy_q)) * (1.0 / 16.0);
          // vv[0]=A, vv[1]=B, vv[2]=C
          s1x = ax_f; s1y = ay_f;
          s2x = bx_f; s2y = by_f;
          s3x = cx_f; s3y = cy_f;
          // stable sort of 3 by y ascending (gold's exact 3 compares):
          //   if (vv[1].y < vv[0].y) swap(vv[0],vv[1]);
          //   if (vv[2].y < vv[1].y) swap(vv[1],vv[2]);
          //   if (vv[1].y < vv[0].y) swap(vv[0],vv[1]);
          if (s2y < s1y) begin
            t = s1x; s1x = s2x; s2x = t;
            t = s1y; s1y = s2y; s2y = t;
          end
          if (s3y < s2y) begin
            t = s2x; s2x = s3x; s3x = t;
            t = s2y; s2y = s3y; s3y = t;
          end
          if (s2y < s1y) begin
            t = s1x; s1x = s2x; s2x = t;
            t = s1y; s1y = s2y; s2y = t;
          end
          v1x_q <= s1x; v1y_q <= s1y;
          v2x_q <= s2x; v2y_q <= s2y;

          d13 = (s3y != s1y) ? (s3x - s1x) / (s3y - s1y) : 0.0;
          d12 = (s2y != s1y) ? (s2x - s1x) / (s2y - s1y) : 0.0;
          d23 = (s3y != s2y) ? (s3x - s2x) / (s3y - s2y) : 0.0;
          dxdy13_q <= d13;
          dxdy12_q <= d12;
          dxdy23_q <= d23;

          // iterator origin = ORIGINAL vertex A, arithmetic floor (gold asr32)
          ox_q <= 32'($signed(ax_q)) >>> 4;

          // iy1=round(v1y), iy3=round(v3y), clip y to [ct, cb)
          iy1 = round_coordinate(s1y);
          iy3 = round_coordinate(s3y);
          if (iy1 < $signed(ct32)) iy1 = $signed(ct32);
          if (iy3 > $signed(cb32)) iy3 = $signed(cb32);

          y_q    <= iy1;
          yend_q <= iy3;
          ch_q   <= 4'd0;
          if (iy1 >= iy3)
            state_q <= R_FLUSH;          // no candidate rows at all
          else begin
            // seed dy0 = curscan - oy for the first scanline's R_ROWINIT
            dy0_q   <= iy1 - (32'($signed(ay_q)) >>> 4);
            state_q <= R_ROWINIT;
          end
        end

        R_ROWINIT: begin
          // rowP = startP + (curscan-oy)*dPdY  (mod 2^32 / 2^64)
          rowp[ch_q] <= ch_start[ch_q] + mul_p;
          if (ch_q == 4'd8) begin
            ch_q    <= 4'd0;
            state_q <= R_SPAN;
          end else
            ch_q <= ch_q + 4'd1;
        end

        // ------------------------------------------------------------
        R_SPAN: begin
          if (empty_c)
            state_q <= R_NEXTROW;
          else begin
            first_q <= first_c;
            last_q  <= last_c;
            dx0_q   <= first_c - ox_q;
            ch_q    <= 4'd0;
            state_q <= R_SPANINIT;
          end
        end

        R_SPANINIT: begin
          // pixP = rowP + (left-ox)*dPdX  (mod 2^32 / 2^64)
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
              // always walk forward (left->right); winding handled by lo/hi swap
              x_q <= x_q + 32'sd1;
              for (int i = 0; i < 9; i++)
                pixp[i] <= pixp[i] + ch_dx[i];
            end
          end
        end

        R_NEXTROW: begin
          for (int i = 0; i < 9; i++)
            rowp[i] <= rowp[i] + ch_dy[i];
          y_q   <= y_q + 32'sd1;
          if (y_q + 32'sd1 >= yend_q)
            state_q <= R_FLUSH;
          else
            state_q <= R_SPAN;
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
                       tri_params.rowpixels, tri_params.yorigin,
                       sign_q};  // sign latched but unused (winding-agnostic raster)

endmodule
