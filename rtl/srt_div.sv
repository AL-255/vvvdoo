// srt_div.sv — radix-4 SRT signed integer divider (FPGA-synthesizable).
//
// Replaces the combinational `/` in the VOODOO_INT raster/TMU datapath (the
// ~630-level / ~570-CARRY8 cone that pins voodoo_top to ~14 MHz on a ZU15EG —
// see fpga/reports/ZU15EG-REPORT.md). Computes trunc(a/b) toward zero, BIT-
// IDENTICAL to SystemVerilog signed `/` (and `r` to `%`), so the integer
// backend's pixels are unchanged (make rmse / cosim stay faithful).
//
// Core: genuine radix-4 SRT. The quotient-digit selection PLA is the Pentium
// Coe-Tang table ported VERBATIM from ventium (fpu_x87_pkg::fx_srt_pla, minus
// the FDIV-bug cells) — Edelman 1997 / Shirriff 2024. The partial remainder is
// kept NON-redundant (true two's complement) so every step is exact and the
// design is verifiable against `/`; digit selection still reads only the top
// 4int.3frac bits, so a step is one short add + small mux, not a full compare.
//
//   * Operands are normalized to significands in [1,2) (matching the PLA's
//     divisor column d4 = DA[62:59]); the SRT yields the 72-bit fraction of
//     |a|/|b|; the integer quotient is that fraction shifted by the exponent
//     difference, then nudged by a single |a|-q*|b| residual correction so the
//     floor is exact regardless of the last SRT digit.
//
// Parameterized (both forms from one source):
//   PIPELINED=0 (default): iterative FSM, STEP_PER_CYC radix-4 steps/clock,
//                          one divide in flight. Small area; fits the existing
//                          per-pixel / per-triangle FSMs that issue one divide.
//   PIPELINED=1          : fully unrolled, one registered stage per radix-4
//                          step -> 1 result/clock throughput (for a future
//                          streaming pixel pipe, M7). ~NSTEP datapath copies.
//
// Handshake: assert in_valid with a,b stable; when in_ready, the op is taken.
// out_valid pulses (iterative) / flows (pipelined) with q,r,derr valid. b==0 is
// the caller's responsibility (raster/TMU guard it); derr flags it, q=r=0.
`default_nettype none

module srt_div #(
    parameter int unsigned W            = 64,  // signed operand / quotient width
    parameter int unsigned STEP_PER_CYC = 2,   // radix-4 steps per clock (iter)
    parameter bit          PIPELINED    = 1'b0
) (
    input  wire logic              clk,
    input  wire logic              rst_n,
    input  wire logic              in_valid,
    output wire logic              in_ready,
    input  wire logic signed [W-1:0] a,        // dividend
    input  wire logic signed [W-1:0] b,        // divisor
    output wire logic              out_valid,
    output wire logic signed [W-1:0] q,        // trunc(a/b)  (== signed `/`)
    output wire logic signed [W-1:0] r,        // a - q*b     (== signed `%`)
    output wire logic              derr        // divide-by-zero (b==0)
);
  // ---- fixed-point geometry (significands in [1,2), 72 fraction bits) -------
  localparam int unsigned FRAC  = 72;
  localparam int unsigned NSTEP = (FRAC/2);          // 36 radix-4 digits
  localparam int unsigned PW    = FRAC + 12;         // partial-remainder width
  localparam int unsigned QW    = FRAC + 16;         // quotient accumulator width
  // The recurrence is w_{j+1}=4*(w_j - q_j*d) (ventium form), so digit k carries
  // weight 4^(NSTEP-1-k); the accumulator therefore equals (|a|/|b|)*2^QSCALE
  // with QSCALE = 2*(NSTEP-1), NOT 2*NSTEP. Integer quotient = floor of that
  // shifted by the exponent difference.
  localparam int unsigned QSCALE = 2*(NSTEP-1);      // = 70

  // ==========================================================================
  // Quotient-digit selection PLA — ported from ventium fpu_x87_pkg::fx_srt_pla
  // (FDIV-bug cells dropped). P_idx: signed 4int.3frac index = top bits of the
  // partial remainder; d4: divisor fraction DA[62:59]; returns digit {-2..2}.
  // ==========================================================================
  function automatic logic signed [2:0] srt_pla(input logic signed [6:0] P_idx,
                                                 input logic [3:0] d4);
    logic signed [6:0] t2, t1, t0, tm1;
    begin
      unique case (d4)
        4'd0 : begin t2= 7'sd12; t1= 7'sd3; t0= -7'sd4; tm1= -7'sd13; end
        4'd1 : begin t2= 7'sd12; t1= 7'sd3; t0= -7'sd4; tm1= -7'sd13; end
        4'd2 : begin t2= 7'sd13; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd14; end
        4'd3 : begin t2= 7'sd14; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd15; end
        4'd4 : begin t2= 7'sd14; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd15; end
        4'd5 : begin t2= 7'sd15; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd16; end
        4'd6 : begin t2= 7'sd16; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd17; end
        4'd7 : begin t2= 7'sd16; t1= 7'sd4; t0= -7'sd5; tm1= -7'sd17; end
        4'd8 : begin t2= 7'sd17; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd18; end
        4'd9 : begin t2= 7'sd18; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd19; end
        4'd10: begin t2= 7'sd18; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd19; end
        4'd11: begin t2= 7'sd19; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd20; end
        4'd12: begin t2= 7'sd20; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd21; end
        4'd13: begin t2= 7'sd20; t1= 7'sd5; t0= -7'sd6; tm1= -7'sd21; end
        4'd14: begin t2= 7'sd21; t1= 7'sd6; t0= -7'sd7; tm1= -7'sd22; end
        4'd15: begin t2= 7'sd22; t1= 7'sd6; t0= -7'sd7; tm1= -7'sd23; end
        default: begin t2=7'sd0; t1=7'sd0; t0=7'sd0; tm1=7'sd0; end
      endcase
      if      (P_idx >= t2)  srt_pla =  3'sd2;
      else if (P_idx >= t1)  srt_pla =  3'sd1;
      else if (P_idx >= t0)  srt_pla =  3'sd0;
      else if (P_idx >= tm1) srt_pla = -3'sd1;
      else                   srt_pla = -3'sd2;
    end
  endfunction

  // ---- count leading zeros (W-bit), W..0 ; clz(0)=W ------------------------
  function automatic logic [$clog2(W+1)-1:0] clz(input logic [W-1:0] x);
    logic [$clog2(W+1)-1:0] n;
    begin
      n = W[$clog2(W+1)-1:0];
      for (int i = W-1; i >= 0; i--)
        if (x[i]) begin n = ($clog2(W+1))'(W-1-i); break; end
      clz = n;
    end
  endfunction

  // ---- one radix-4 SRT step: select digit from S, return (S<<... ) ----------
  // S holds the partial remainder (value*2^FRAC). da = |b| significand placed
  // with its leading 1 at bit FRAC. Returns the next partial remainder and the
  // quotient digit. (P_idx = signed bits [FRAC+3 : FRAC-3] of S.)
  function automatic logic signed [PW-1:0] step_next(input logic signed [PW-1:0] S,
                                                      input logic        [PW-1:0] da,
                                                      input logic        [3:0]    d4,
                                                      output logic signed [2:0]   qd);
    logic signed [6:0]  pidx;
    logic signed [PW-1:0] sub;
    begin
      pidx = S[FRAC+3 : FRAC-3];
      qd   = srt_pla(pidx, d4);
      // da's leading 1 sits at bit FRAC (< PW-1), so {da, da<<1} are positive
      // when read as signed PW-bit; no extra guard bit needed.
      unique case (qd)
        3'sd2:   sub = S - $signed(da << 1);
        3'sd1:   sub = S - $signed(da);
        3'sd0:   sub = S;
        -3'sd1:  sub = S + $signed(da);
        default: sub = S + $signed(da << 1);            // -2
      endcase
      step_next = sub <<< 2;                            // *4 for the next digit
    end
  endfunction

  // ==========================================================================
  // operand setup (shared) : magnitudes, normalization, exponent difference.
  // ==========================================================================
  // Combinational decode of the launch operands.
  function automatic void decode(input logic signed [W-1:0] aa,
                                 input logic signed [W-1:0] bb,
                                 output logic [W-1:0] mag_a, output logic [W-1:0] mag_b,
                                 output logic [PW-1:0] s0, output logic [PW-1:0] da_fx,
                                 output logic [3:0] d4, output logic signed [31:0] expdiff,
                                 output logic a_zero, output logic b_zero,
                                 output logic q_neg, output logic r_neg);
    logic [W-1:0] na, db;
    logic [$clog2(W+1)-1:0] clza, clzb;
    begin
      mag_a  = aa[W-1] ? (~aa + 1'b1) : aa;
      mag_b  = bb[W-1] ? (~bb + 1'b1) : bb;
      a_zero = (mag_a == '0);
      b_zero = (mag_b == '0);
      q_neg  = aa[W-1] ^ bb[W-1];
      r_neg  = aa[W-1];
      clza   = clz(mag_a);
      clzb   = clz(mag_b);
      na     = mag_a << clza;          // MSB at bit W-1
      db     = mag_b << clzb;
      // place leading 1 at bit FRAC : value*2^FRAC with significand in [1,2)
      s0     = (PW'({1'b0, na})) << (FRAC - (W-1));
      da_fx  = (PW'({1'b0, db})) << (FRAC - (W-1));
      d4     = db[W-2 -: 4];
      expdiff= 32'($signed({1'b0, clzb})) - 32'($signed({1'b0, clza}));  // msb(a)-msb(b)
    end
  endfunction

  // ==========================================================================
  // final integer extraction, split so the |Q|*|b| multiply sits in its own
  // pipeline stage (it was the post-divide critical path):
  //   qm_calc     : |Q|_candidate = floor(qacc >> (QSCALE - expdiff))
  //   <stage>     : res = |a| - qm*|b|              (one DSP multiply+subtract)
  //   floor_correct: nudge qm by +-1/+-2 so res in [0,|b|) (covers the SRT ulp),
  //                  then apply the x86-style signs -> q == a/b, r == a%b.
  // ==========================================================================
  localparam int unsigned RW = 2*W+2;               // wide residual width

  function automatic logic [W-1:0] qm_calc(input logic [QW-1:0] qacc,
                                           input logic signed [31:0] expdiff,
                                           input logic a_zero);
    logic signed [31:0] sh;
    begin
      sh = $signed(32'(QSCALE)) - expdiff;
      if (a_zero || sh >= $signed(32'(QW)) || sh < 0) qm_calc = '0;
      else                                            qm_calc = W'(qacc >> sh[$clog2(QW)-1:0]);
    end
  endfunction

  function automatic logic signed [RW-1:0] wide(input logic [W-1:0] x);
    wide = $signed({{(RW-W){1'b0}}, x});
  endfunction

  function automatic void floor_correct(input logic [W-1:0] qm_in,
                                         input logic signed [RW-1:0] res_in,
                                         input logic [W-1:0] mag_b,
                                         input logic a_zero, input logic q_neg, input logic r_neg,
                                         output logic signed [W-1:0] qo, output logic signed [W-1:0] ro);
    logic [W-1:0]          qm;
    logic signed [RW-1:0]  res, mbw;
    begin
      qm = qm_in; res = res_in; mbw = wide(mag_b);
      if (!a_zero) begin
        for (int it = 0; it < 2; it++) begin
          if (res < 0)         begin qm = qm - 1'b1; res = res + mbw; end
          else if (res >= mbw) begin qm = qm + 1'b1; res = res - mbw; end
        end
      end
      qo = q_neg ? (~qm + 1'b1) : qm;                                   // == a/b
      ro = r_neg ? (~res[W-1:0] + 1'b1) : res[W-1:0];                   // == a%b
    end
  endfunction

  // ==========================================================================
  generate
  if (!PIPELINED) begin : g_iter
    // ------------------------------------------------------------------ ITER
    typedef enum logic [2:0] { ST_IDLE, ST_RUN, ST_QM, ST_MUL, ST_FIN } state_t;
    state_t st;
    logic signed [PW-1:0] S;
    logic [QW-1:0]        qacc;
    logic [PW-1:0]        da_fx;
    logic [3:0]           d4;
    logic [W-1:0]         mag_a, mag_b, qm_q;
    logic signed [RW-1:0] res_q;
    logic signed [31:0]   expdiff;
    logic                 a_zero, q_neg, r_neg;
    logic [$clog2(NSTEP+1)-1:0] k;
    logic signed [W-1:0]  q_q, r_q;
    logic                 derr_q, ov_q;

    assign in_ready  = (st == ST_IDLE);
    assign out_valid = ov_q;
    assign q = q_q; assign r = r_q; assign derr = derr_q;

    always_ff @(posedge clk) begin
      if (!rst_n) begin st <= ST_IDLE; ov_q <= 1'b0; end
      else begin
        ov_q <= 1'b0;
        unique case (st)
          ST_IDLE: if (in_valid) begin
            logic [W-1:0] ma, mb; logic [PW-1:0] s0, df; logic [3:0] dd;
            logic signed [31:0] ed; logic az, bz, qn, rn;
            ma=0; mb=0; s0=0; df=0; dd=0; ed=0; az=0; bz=0; qn=0; rn=0;
            decode(a, b, ma, mb, s0, df, dd, ed, az, bz, qn, rn);
            mag_a<=ma; mag_b<=mb; da_fx<=df; d4<=dd; expdiff<=ed;
            a_zero<=az; q_neg<=qn; r_neg<=rn;
            S <= s0; qacc <= '0; k <= '0;
            if (bz) begin q_q<='0; r_q<='0; derr_q<=1'b1; ov_q<=1'b1; st<=ST_IDLE; end
            else    begin derr_q<=1'b0; st<=ST_RUN; end
          end
          ST_RUN: begin
            logic signed [PW-1:0] s_v;
            logic [QW-1:0]        acc;
            logic [$clog2(NSTEP+1)-1:0] kk;
            logic signed [2:0] qd;
            logic signed [PW-1:0] sn;
            s_v = S; acc = qacc; kk = k; qd = 0; sn = 0;
            for (int i = 0; i < STEP_PER_CYC; i++) begin
              if (32'(kk) < NSTEP) begin
                sn  = step_next(s_v, da_fx, d4, qd);
                acc = acc + (QW'($signed(qd)) <<< (QSCALE - 2*int'(kk)));
                s_v = sn;
                kk  = kk + 1'b1;
              end
            end
            S <= s_v; qacc <= acc; k <= kk;
            if (32'(kk) >= NSTEP) st <= ST_QM;
          end
          ST_QM: begin                       // shift qacc -> candidate |Q|
            qm_q <= qm_calc(qacc, expdiff, a_zero);
            st   <= ST_MUL;
          end
          ST_MUL: begin                      // res = |a| - |Q|*|b|  (DSP stage)
            res_q <= wide(mag_a) - wide(qm_q) * wide(mag_b);
            st    <= ST_FIN;
          end
          ST_FIN: begin                      // nudge to exact floor + sign
            logic signed [W-1:0] qo, ro;
            floor_correct(qm_q, res_q, mag_b, a_zero, q_neg, r_neg, qo, ro);
            q_q<=qo; r_q<=ro; ov_q<=1'b1; st<=ST_IDLE;
          end
          default: st <= ST_IDLE;
        endcase
      end
    end
  end else begin : g_pipe
    // -------------------------------------------------------------- PIPELINED
    // One registered stage per radix-4 step. Stage 0 = decode; stages 1..NSTEP
    // each apply step_next and accumulate; stage NSTEP+1 = finish. Throughput
    // is one divide/clock; latency NSTEP+2.
    typedef struct packed {
      logic                 vld;
      logic signed [PW-1:0] S;
      logic [QW-1:0]        qacc;
      logic [PW-1:0]        da_fx;
      logic [3:0]           d4;
      logic [W-1:0]         mag_a, mag_b;
      logic signed [31:0]   expdiff;
      logic                 a_zero, b_zero, q_neg, r_neg;
    } stg_t;
    stg_t stg [0:NSTEP];      // stg[0] post-decode, stg[NSTEP] after last step

    assign in_ready = 1'b1;   // pipelined: always accepts

    // stage 0 : decode
    always_ff @(posedge clk) begin
      if (!rst_n) stg[0].vld <= 1'b0;
      else begin
        logic [W-1:0] ma, mb; logic [PW-1:0] s0, df; logic [3:0] dd;
        logic signed [31:0] ed; logic az, bz, qn, rn;
        decode(a, b, ma, mb, s0, df, dd, ed, az, bz, qn, rn);
        stg[0].vld<=in_valid; stg[0].S<=s0; stg[0].qacc<='0; stg[0].da_fx<=df;
        stg[0].d4<=dd; stg[0].mag_a<=ma; stg[0].mag_b<=mb; stg[0].expdiff<=ed;
        stg[0].a_zero<=az; stg[0].b_zero<=bz; stg[0].q_neg<=qn; stg[0].r_neg<=rn;
      end
    end
    // stages 1..NSTEP : one radix-4 step each
    genvar gi;
    for (gi = 1; gi <= NSTEP; gi++) begin : g_stage
      always_ff @(posedge clk) begin
        if (!rst_n) stg[gi].vld <= 1'b0;
        else begin
          logic signed [2:0] qd; logic signed [PW-1:0] sn;
          stg[gi] <= stg[gi-1];
          sn = step_next(stg[gi-1].S, stg[gi-1].da_fx, stg[gi-1].d4, qd);
          stg[gi].S    <= sn;
          stg[gi].qacc <= stg[gi-1].qacc + (QW'($signed(qd)) <<< (QSCALE - 2*(gi-1)));
        end
      end
    end
    // final stages : qm (shift) -> res (multiply) -> correct+sign. Three
    // registered stages mirror the iterative ST_QM/ST_MUL/ST_FIN so the |Q|*|b|
    // multiply gets its own stage (same critical-path split, throughput 1/clk).
    logic                qm_vld, qm_bz, qm_az, qm_qn, qm_rn;
    logic [W-1:0]        qm_v, qm_mb, qm_ma;
    logic                ml_vld, ml_bz, ml_az, ml_qn, ml_rn;
    logic [W-1:0]        ml_qm, ml_mb;
    logic signed [RW-1:0] ml_res;
    logic signed [W-1:0] q_q, r_q; logic ov_q, derr_q;

    // stage A : candidate |Q| (shift), carry |a|,|b| and flags
    always_ff @(posedge clk) begin
      if (!rst_n) qm_vld <= 1'b0;
      else begin
        qm_vld <= stg[NSTEP].vld; qm_bz <= stg[NSTEP].b_zero;
        qm_az  <= stg[NSTEP].a_zero; qm_qn <= stg[NSTEP].q_neg; qm_rn <= stg[NSTEP].r_neg;
        qm_v   <= qm_calc(stg[NSTEP].qacc, stg[NSTEP].expdiff, stg[NSTEP].a_zero);
        qm_ma  <= stg[NSTEP].mag_a; qm_mb <= stg[NSTEP].mag_b;
      end
    end
    // stage B : res = |a| - |Q|*|b|  (DSP multiply+subtract)
    always_ff @(posedge clk) begin
      if (!rst_n) ml_vld <= 1'b0;
      else begin
        ml_vld <= qm_vld; ml_bz <= qm_bz; ml_az <= qm_az; ml_qn <= qm_qn; ml_rn <= qm_rn;
        ml_qm  <= qm_v;   ml_mb <= qm_mb;
        ml_res <= wide(qm_ma) - wide(qm_v) * wide(qm_mb);
      end
    end
    // stage C : exact-floor correction + sign
    always_ff @(posedge clk) begin
      if (!rst_n) ov_q <= 1'b0;
      else begin
        logic signed [W-1:0] qo, ro;
        floor_correct(ml_qm, ml_res, ml_mb, ml_az, ml_qn, ml_rn, qo, ro);
        ov_q   <= ml_vld;
        derr_q <= ml_bz;
        q_q    <= ml_bz ? '0 : qo;
        r_q    <= ml_bz ? '0 : ro;
      end
    end
    assign out_valid = ov_q; assign q = q_q; assign r = r_q; assign derr = derr_q;
  end
  endgenerate
endmodule

`default_nettype wire
