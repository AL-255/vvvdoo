# Voodoo SST-1 — Integer (Fixed-Point) Backend IMPLEMENTATION PLAN

Companion to `docs/INT-BACKEND-SPEC.md` (the arithmetic spec). This file is the build flag
wiring, per-file edit plan, RMSE harness, build-clean checklist, and risk register.

**Architectural ground truth (verified against the tree):**
- Float lives in **exactly two RTL files**: `rtl/raster.sv` (coverage rounding) and
  `rtl/tmu.sv` (perspective divide + log2). `rtl/pixel_pipe.sv`, `rtl/float_conv.sv`,
  `rtl/voodoo_pkg.sv` contain **no float ops** (verified) — `float_conv.sv` and
  `pixel_pipe.sv` `wfloatf` are already integer "float-in-int" idioms and are the
  templates the new helpers mirror.
- There are **currently no `` `ifdef ``/`` `define `` blocks in `rtl/`** (verified). The
  `VOODOO_INT` switch is new; RTL must learn to honor it.
- The gate is `make test` = Verilator trace-diff vs `model/voodoo_gold.c` (C `double`).
  `INT=0` MUST stay pixel-exact; `INT=1` is **judged by RMSE**, never by `make test`.

---

## 2. FLAG — Makefile edits (`make INT=1` → `+define+VOODOO_INT` across all 4 Verilator invocations)

`make INT=1` must append `+define+VOODOO_INT` to **lint, sim, cosim, cosim-lib**. The
real Makefile uses `RTL_CFG := $(wildcard rtl/*.vlt)` and `-Mdir … -o … ; cp …`. The four
Verilator invocations are at lines **45, 55, 78, 99**.

### 2.1 New INT/VDEFS block — insert immediately after line 15 (`RTL_TOP := voodoo_top`)

```makefile
# INT=1 builds the fixed-point (VOODOO_INT) datapath: appends +define+VOODOO_INT to
# every verilator invocation (lint/sim/cosim/cosim-lib). INT=0 (default) is the float
# datapath that is pixel-exact vs the gold model — the `make test` contract.
# Verilator obj dirs and output binaries are SUFFIXED with $(INT) so the float and int
# artifacts coexist (the RMSE harness needs both at once) and a stale INT toggle can
# never silently reuse the wrong generated C++.
INT   ?= 0
VDEFS :=
ifeq ($(INT),1)
VDEFS += +define+VOODOO_INT
endif
```

### 2.2 Thread `$(VDEFS)` + suffix the obj dirs / binaries

Place `$(VDEFS)` immediately before `$(RTL_CFG)` in each recipe (`+define+` is
order-independent for Verilator; at `INT=0`, `VDEFS` is empty so the command lines are
byte-identical to today → zero risk to the default path). Suffix `-Mdir`/`-o`/`cp` targets
with `$(INT)`.

**`lint` (line 45):**
```makefile
	$(VERILATOR) --lint-only -Wall --top-module $(RTL_TOP) $(VDEFS) $(RTL_CFG) $(RTL_SRCS)
```

**`sim` (lines 55-56):**
```makefile
	$(VERILATOR) $(VSIM_FLAGS) -Mdir $(BUILD)/vsim_obj$(INT) -o vsim$(INT) \
	    $(VDEFS) $(RTL_CFG) $(RTL_SRCS) $(abspath tb/frame/tb_main.cpp)
	cp $(BUILD)/vsim_obj$(INT)/vsim$(INT) $(BUILD)/vsim$(INT)
```
> `make test` targets (lines ~58-72) run `$(BUILD)/vsim`. Keep them on the **unsuffixed**
> `vsim` and force `INT=0` for the test contract. Simplest: leave the `test-mN` recipes
> calling `$(BUILD)/vsim` and add `vsim: ` alias → see §5. (Do **not** wire `INT=1` into
> `test`.)

**`cosim` (lines 78-79):**
```makefile
	$(VERILATOR) $(COSIM_FLAGS) -Mdir $(BUILD)/cosim_obj$(INT) -o cosim_replay$(INT) \
	    $(VDEFS) $(RTL_CFG) $(RTL_SRCS) $(abspath cosim/cosim_replay.cpp)
	cp $(BUILD)/cosim_obj$(INT)/cosim_replay$(INT) $(BUILD)/cosim_replay$(INT)
```
> The RMSE harness (§4) runs `$(BUILD)/cosim_replay0` (float) and
> `$(BUILD)/cosim_replay1` (int). `cosim-run` (line ~81) keeps using `cosim_replay0`.

**`cosim-lib` (lines 99-105):**
```makefile
	$(VERILATOR) --cc -O3 -j 0 --top-module $(RTL_TOP) \
	    -CFLAGS "-std=c++17 -O2 -fPIC -I$(VOODOO_INC)" \
	    -Mdir $(VRTL_OBJDIR) \
	    $(VDEFS) $(RTL_CFG) $(RTL_SRCS) $(abspath cosim/voodoo_rtl.cpp)
```
> `cosim-lib` builds the single QEMU static lib; pick the datapath at build time via
> `make cosim-lib INT=1`. (If both libs must coexist, also suffix `VRTL_OBJDIR`/`VRTL_LIB`
> with `$(INT)`; one-at-a-time is fine for now.)

### 2.3 What must NOT get `$(VDEFS)`

The gold/tool **C** compiles (libvgold, vgold_replay, tracegen, unit tests, the new
`ppm_rmse`) are the float reference and must stay untouched — `+define+VOODOO_INT` goes
**only** on the 4 *verilator* lines. The gold model has no INT analog.

---

## 3. PER-FILE EDITS

Pattern everywhere: wrap each existing float region in
`` `ifndef VOODOO_INT `` … `` `else `` … `` `endif `` so the **float path stays the
default (INT=0)** and the integer path is added **alongside** under `` `else ``. Reuse the
already-integer surrounding logic (iterator DDA, LOD-resolve, addressing, combine) — those
are NOT touched.

### 3.0 Shared fixed-point helpers — where they live

Add a small package of reusable integer helpers so raster and tmu share one
implementation. **Location: append to `rtl/voodoo_pkg.sv`** (it is `import`ed by both
modules and is pure-integer). Guard each with `` `ifdef VOODOO_INT `` since they are only
referenced by the int path (keeps INT=0 elaboration identical). Functions (names are
normative):

| Helper | Signature | Purpose | Spec ref |
|---|---|---|---|
| `vd_clz64` | `function automatic int vd_clz64(input logic [63:0] v)` | count leading zeros (leading-one detect) for log2/reciprocal normalize | mirrors `wfloatf` CLZ in `pixel_pipe.sv` |
| `vd_log2_mant` | `function automatic logic [7:0] vd_log2_mant(input logic [6:0] m)` | 128×8 mantissa LUT, `round(256·log2(1.m))` | SPEC §6.2 **[UNSPEC-BY-DOC]** |
| `vd_log2_int` | `function automatic logic signed [31:0] vd_log2_int(input logic [127:0] value, input int fracbits)` | integer log2 → signed x.8 (CLZ + LUT) | SPEC §6.1/§6.2 |
| `vd_recip_w` | `function automatic logic signed [31:0] vd_recip_w(input logic signed [63:0] iterw)` | reciprocal `256/iterw`, scaled ×256, signed | SPEC §5.2 **[UNSPEC-BY-DOC]** |
| `vd_asr_trunc64` | `function automatic logic signed [63:0] vd_asr_trunc64(input logic signed [63:0] v, input int n)` | shift-right **truncating toward zero** (matches `$rtoi`/affine) | SPEC §5.2 |
| `vd_edge_x` | `function automatic logic signed [31:0] vd_edge_x(... S11.4 endpoints, row y)` | S11.4 edge-X at a scanline (DDA) | SPEC §4.3 |
| `vd_ceil_s11_4` | `function automatic logic signed [31:0] vd_ceil_s11_4(input logic signed [31:0] x_s11_4)` | `(x + 0x0F) >> 4` ceil-to-integer-pixel | SPEC §4.3 step 2 |

> `vd_recip_w` and `vd_log2_mant` are the **two [UNSPEC-BY-DOC] blocks** — their table
> sizes/contents are free parameters to characterize against the RMSE harness (SPEC §5.2,
> §6.2). Start: `vd_recip_w` = leading-one normalize + ≥7-bit mantissa recip LUT + 1
> Newton step (≥18 result bits); `vd_log2_mant` = 128×8 keyed on 7 mantissa bits.

### 3.1 `rtl/raster.sv` — coverage rounding (FLOAT regions 1a–1d)

Float sites: `round_coordinate` (lines 69–73, `$floor`/`$rtoi`), the per-scanline span
combinational block (lines 151–171, `real fully_c/startx_c/stopx_c`), R_SETUP vert
setup/sort/slopes (lines 280–319, `real` locals), and the `real` `_q` state regs (lines
111–112). The iterator DDA (`mul_p`, `rowp/pixp`, lines 138–146, 176–177, 342–419) is
**already integer — untouched**.

**Edit A — span scalar state regs (lines 111-112):**
```systemverilog
`ifndef VOODOO_INT
  real v1x_q, v1y_q, v2x_q, v2y_q;
  real dxdy13_q, dxdy12_q, dxdy23_q;
`else
  // S11.4 sorted verts (widened to S27.4) + edge slopes as S27.4 DDA increments.
  logic signed [31:0] v1x_q, v1y_q, v2x_q, v2y_q;   // S27.4 (4 frac bits)
  logic signed [31:0] dxdy13_q, dxdy12_q, dxdy23_q; // S27.4 slope per +1 row
`endif
```
> Reset block (lines 201-202): guard the `0.0` resets vs `'0` the same way.

**Edit B — `round_coordinate` (lines 69-73):** keep the float function under `` `ifndef ``;
under `` `else `` it is **not needed** (the INT span uses `vd_ceil_s11_4` + the row-range
test from SPEC §4.3, not round-to-nearest). No INT replacement of `round_coordinate`.

**Edit C — per-scanline span (lines 155-171):** keep float `always_comb` under
`` `ifndef ``. Under `` `else `` compute the §4.3 integer span. `y_q` is the integer
scanline; verts/slopes are S27.4:
```systemverilog
`else
  always_comb begin
    logic signed [31:0] xL_s4, xR_s4;       // S27.4 left/right edge X at row y_q
    logic signed [31:0] startx, stopx;       // integer pixel columns
    // edge X at integer row y_q (S11.4 domain): x0 + (y - y0)*slope, carried S27.4
    xL_s4 = vd_edge_x(v1x_q, v1y_q, dxdy13_q, y_q);                 // major edge AC
    xR_s4 = (($signed(y_q) <<< 4) < v2y_q)                          // minor: AB upper, BC lower
            ? vd_edge_x(v1x_q, v1y_q, dxdy12_q, y_q)
            : vd_edge_x(v2x_q, v2y_q, dxdy23_q, y_q);
    startx = vd_ceil_s11_4((xL_s4 <= xR_s4) ? xL_s4 : xR_s4);       // left-in: ceil
    stopx  = vd_ceil_s11_4((xL_s4 <= xR_s4) ? xR_s4 : xL_s4) - 1;   // right-out: ceil-1
    if ($signed(startx) < cl32) startx = cl32;
    if ($signed(stopx)  > (cr32 - 1)) stopx = cr32 - 1;             // right EXCLUSIVE
    first_c = startx;
    last_c  = stopx;
    empty_c = ($signed(startx) > $signed(stopx));
  end
`endif
```
> `first_c/last_c/empty_c` are the existing 32-bit outputs the FSM consumes (lines
> 357-362) — interface unchanged. Winding handled by the min/max on xL/xR (mirrors the
> existing float lo/hi swap), so `sign_q` stays unused.

**Edit D — R_SETUP (lines 280-340):** keep the float vert/sort/slope block under
`` `ifndef ``. Under `` `else ``: sort the three S11.4 verts by Y (integer compares,
**strict `<`** to match the stable-sort tie behavior), widen to S27.4, and compute slopes
as **S27.4 DDA increments**. Two honest options for the slope, pick per RMSE:
- (preferred, exact-DDA) carry the edge as `(dx_s4, dy_s4)` and recompute X by integer
  `mul/div` per row inside `vd_edge_x` (one signed divide per scanline at setup-time
  precision), OR
- (cheaper) precompute `slope_s4 = (dx_s4 << K) / dy_s4` with K guard bits and accumulate.

  The row range uses the §4.3 test: set `y_q <= ` first integer row with
  `(y<<4) ≥ v1y` (i.e. `ceil(v1y/16)`), `yend_q <= ` first row with `(y<<4) ≥ v3y`,
  clipped to `[ct,cb)`. The integer origin `ox_q` (line 322) and `dy0_q` (line 337) are
  **already integer and unchanged** (they seed the exact integer iterators).

### 3.2 `rtl/tmu.sv` — perspective divide + log2 (FLOAT regions 2a–2c)

Float sites: `fast_log2f` (lines 86–104, `$realtobits`), `S_LODBASE` (lines 450–466,
`real` sum-of-squares + `fast_log2f`), `S_DIV` (lines 477–499, `real` `256.0/iterw`
divide + `$rtoi`). Everything else (LOD-resolve 303–322, addressing 330–351, bilinear
355–367, `tex_combine` 236–294, expand 182–231) is **already integer — untouched**.

**Edit A — `fast_log2f` (lines 86-104):** keep under `` `ifndef ``. No `` `else `` body is
needed inside tmu.sv because the integer log2 lives in the shared `vd_log2_int`
(§3.0) — callers just switch which they call (Edits B/C).

**Edit B — `S_LODBASE` (lines 450-466):**
```systemverilog
`ifndef VOODOO_INT
  // ... existing real fdsdx.. + fast_log2f(maxval,64) ...
`else
  S_LODBASE: begin
    // exact 128-bit sums-of-squares of the s32 14.18 gradients (SPEC §6.1)
    logic signed [63:0] gx0, gy0, gx1, gy1;
    logic [127:0]       texdx, texdy, maxv;
    gx0 = 64'($signed(tp_q.ds0dx)); gy0 = 64'($signed(tp_q.dt0dx));
    gx1 = 64'($signed(tp_q.ds0dy)); gy1 = 64'($signed(tp_q.dt0dy));
    texdx = ($signed(gx0)*$signed(gx0)) + ($signed(gy0)*$signed(gy0)); // exact, ~128b
    texdy = ($signed(gx1)*$signed(gx1)) + ($signed(gy1)*$signed(gy1));
    maxv  = (texdx > texdy) ? texdx : texdy;
    lodbase_q <= vd_log2_int(maxv, 64) >>> 1;   // /2 toward zero (log2 >= 0 here)
    state_q   <= S_RDY;
  end
`endif
```
> `lodbase_q` is the existing `logic signed [31:0]` (line 156); the LOD-resolve block
> consumes it unchanged. Width note: `ds0dx` etc. are the 14.18 gradients held in
> `tri_params`; widen to 64b before squaring; product fits 128b.

**Edit C — `S_DIV` (lines 477-499):**
```systemverilog
`ifndef VOODOO_INT
  // ... existing real iters/itert/iterw + 256.0/iterw + $rtoi + fast_log2f ...
`else
  S_DIV: begin
    logic signed [63:0] iters, itert, iterw;
    logic signed [31:0] recip;                  // 256/iterw, scaled, signed (SPEC §5.2)
    iters = $signed(s0_q); itert = $signed(t0_q); iterw = $signed(w0_q);
    if (iterw == 64'sd0) iterw = 64'sd1;         // div-by-zero guard (same as float)
    if (tp_q.texmode[0]) begin                   // perspective
      recip       = vd_recip_w(iterw);           // [UNSPEC-BY-DOC] integer reciprocal
      coord_s_q   <= 32'($signed(iters) * $signed(recip) >>> /*recip scale*/ R_SCALE);
      coord_t_q   <= 32'($signed(itert) * $signed(recip) >>> R_SCALE);
      lod_persp_q <= -vd_log2_int({{64{w0_q[63]}}, w0_q} & {127{1'b1}}, 32); // log2(1/W), 32 frac
    end else begin                               // affine: /2^24 truncate toward zero
      coord_s_q   <= 32'(vd_asr_trunc64(iters, 24));
      coord_t_q   <= 32'(vd_asr_trunc64(itert, 24));
      lod_persp_q <= 32'sd0;
    end
    negw_q  <= (iterw < 64'sd0);
    state_q <= S_LODCALC;
  end
`endif
```
> `coord_s_q/coord_t_q/lod_persp_q/negw_q` are the existing `logic signed [31:0]`/1-bit
> regs (lines 162-164); S_LODCALC consumes them unchanged. `R_SCALE` = the fixed scale
> baked into `vd_recip_w` (so `iter * recip >> R_SCALE` lands coords with 8 frac bits at
> the bottom per SPEC §7) — define it as a `localparam` next to `vd_recip_w`. `lod_persp`
> uses `vd_log2_int` on the **positive** 1/W magnitude (negative → 0 by the helper guard,
> matching `fast_log2`'s `value<0 → 0`).

### 3.3 `rtl/pixel_pipe.sv` — NO EDIT

Verified zero float ops. `wfloatf` (CLZ + exp + mantissa pack), `clamp_argbf`,
`clamped_zf`, `clamped_wf`, `combine_colorf`, `apply_fogf`, `blend_scalef`,
`alpha_blendf` are all integer and already synthesizable. **No `VOODOO_INT` work.** It is
the reference idiom the new `vd_log2_int`/`vd_recip_w` CLZ-normalize mirrors.

### 3.4 `rtl/float_conv.sv` — NO EDIT

Despite the name, already pure-integer (IEEE-754 bit-field → fixed-point via exponent
arithmetic + shifts, `fixedbits` = 4/12/32). Used identically by both paths. **No
`VOODOO_INT` work.** Template for "float in integers."

### 3.5 `rtl/voodoo_pkg.sv` — ADD the shared helpers (§3.0) under `` `ifdef VOODOO_INT ``

Only addition is the helper functions. No struct/format changes — all the iterator/clip
fields already carry the doc formats. At `INT=0` the `` `ifdef `` block is skipped, so
elaboration is byte-identical to today.

### 3.6 Interfaces — NO PORT/WIDTH CHANGES anywhere

Both `raster` and `tmu` expose **only integer-valued** module boundaries (`px_*`,
`smp_*`/`tex_*`, `trd_addr`). All float is internal state. Verified against
`rtl/voodoo_top.sv` instantiations — the `VOODOO_INT` swap is purely internal to the two
modules; `voodoo_top.sv` is untouched.

---

## 4. RMSE — `tools/ppm_rmse.c` + render/compare commands

### 4.1 `tools/ppm_rmse.c` design (dependency-free C11, links `-lm` like the other gold tools)

- **CLI:** `ppm_rmse <a.ppm> <b.ppm> [--max-rmse R] [--min-psnr P]`. Exit **0** =
  success/within-threshold, **1** = threshold exceeded (pass/fail gate), **2** =
  I/O/format/dimension-mismatch.
- **Parser:** P6 only. Read magic `P6`; skip whitespace **and `#` comment lines**; read
  `W H maxval`; require `maxval==255`; one whitespace byte then `fread` exactly `W*H*3`
  bytes. Reject non-P6, maxval≠255, mismatched dims, short read. (`CFLAGS` has
  `-Werror -Wextra`: cast every `fgetc`, check every `fread`/`fscanf` return.)
- **Math (per channel c∈{R,G,B}, N=W·H):** cast bytes to int first (avoid unsigned wrap);
  `SSE_c = Σ(a-b)²` in `double`; `RMSE_c = sqrt(SSE_c/N)`; overall
  `MSE = (SSE_R+SSE_G+SSE_B)/(3N)`, `RMSE = sqrt(MSE)`;
  `PSNR = MSE==0 ? +inf : 10·log10(255²/MSE)` (print `inf` when identical); per-channel
  PSNR from `MSE_c`. Also track `max_abs` (largest single-channel abs diff) and `diffpix`
  (pixels with any channel differing).
- **Output (machine-greppable):**
  ```
  ppm_rmse a.ppm b.ppm : 640x480
    R: rmse=0.000 psnr=inf dB
    G: rmse=1.732 psnr=43.37 dB
    B: rmse=0.998 psnr=48.14 dB
    overall: rmse=1.118 psnr=47.16 dB  (max_abs=7 diffpix=1234/307200)
  ```
- **Makefile rule** (mirror the line-31 tool pattern; needs `-lm`, NOT libvgold) + add to a
  `tools:` phony (or the `gold` aggregate):
  ```makefile
  $(BUILD)/ppm_rmse: tools/ppm_rmse.c | $(BUILD)
  	$(CC) $(CFLAGS) $< -lm -o $@
  ```

> Why P6 parsing matches: the cosim emitter writes `P6\n%d %d\n255\n` (verified
> `cosim/cosim_replay.cpp` line 101), dims from RTL scanout ports (`scan_width/height`,
> fallback 640×480), stride `scan_rowpixels`, base `scan_front_base`, 565→888
> bit-replication — **byte-identical** to gold's `vgold_dump_ppm` and `tb_main.cpp`
> `write_ppm`. So int-vs-float, int-vs-gold, rtl-vs-gold all use this one tool.

### 4.2 Exact commands to render m1..m5 through INT=0 and INT=1 and compare

With the `$(INT)`-suffixed binaries from §2 (`cosim_replay0` = float, `cosim_replay1` =
int), both built once, both PPM sets coexist. The cosim emitter names frames
`<prefix>_f%03d.ppm` (per swap) + `<prefix>_final.ppm` (verified lines 157/176), dims from
RTL ports, so float/int frames pair **1:1**.

```bash
cd /home/yukidama/github/vvvdoo
make gold traces                 # build libvgold + tracegen, regenerate m1..m5 .vvt
make $(BUILD:=)/ppm_rmse 2>/dev/null || make build/ppm_rmse   # build the metric tool

# build both datapaths (suffixed obj dirs -> no clean needed between toggles)
make cosim INT=0                 # -> build/cosim_replay0
make cosim INT=1                 # -> build/cosim_replay1

for t in m1_fill_lfb m2_tri_gouraud m3_selftest_full m4_pipeline m5_texfmt; do
  echo "== $t"
  build/cosim_replay0 tb/traces/$t.vvt build/float_$t  >/dev/null
  build/cosim_replay1 tb/traces/$t.vvt build/int_$t    >/dev/null
  for fp in build/float_${t}_*.ppm; do
    ip=${fp/float_/int_}; [ -f "$ip" ] && build/ppm_rmse "$fp" "$ip"
  done
done
```

**Suggested `rmse` Makefile target** (loops the five traces + every frame):
```makefile
.PHONY: rmse
rmse: $(BUILD)/ppm_rmse traces
	@$(MAKE) cosim INT=0
	@$(MAKE) cosim INT=1
	@set -e; for t in m1_fill_lfb m2_tri_gouraud m3_selftest_full m4_pipeline m5_texfmt; do \
	  echo "== $$t"; \
	  $(BUILD)/cosim_replay0 tb/traces/$$t.vvt $(BUILD)/float_$$t >/dev/null; \
	  $(BUILD)/cosim_replay1 tb/traces/$$t.vvt $(BUILD)/int_$$t   >/dev/null; \
	  for fp in $(BUILD)/float_$${t}_*.ppm; do \
	    ip=$${fp/float_/int_}; [ -f "$$ip" ] && $(BUILD)/ppm_rmse "$$fp" "$$ip"; \
	  done; \
	done
```

**Absolute error vs the float spec (bonus):** also diff INT=1 against the gold reference —
`build/vgold_replay tb/traces/m2_tri_gouraud.vvt /dev/null build/gold_m2.ppm` then
`build/ppm_rmse build/gold_m2.ppm build/int_m2_final.ppm` — giving fixed-point error vs
the float spec, not just vs the float RTL.

### 4.3 Why these five traces

They are the exact set `make test` gates on (so float/INT=0 is known pixel-exact on them),
small/fast vs the 230–250 MB glquake traces, and each isolates a stage: **m1** LFB fills
(FB write path; expect RMSE ~0), **m2** Gouraud (iterated RGBA — most sensitive to coverage
rounding), **m3** full self-test (broadest), **m4** pipeline mix, **m5** texture formats
(TMU divide + log2 — where the [UNSPEC-BY-DOC] reciprocal/log2 error concentrates). All
present and fresh (verified `tb/traces/m{1..5}_*.vvt`), regenerated by `make traces`.

---

## 5. BUILD-CLEAN CHECKLIST

Both datapaths must lint clean and build clean; `INT=0` must stay pixel-exact; `INT=1` is
judged by RMSE.

| # | Command | Expectation |
|---|---|---|
| 1 | `make lint INT=0` | clean (no warnings — `-Wall`; current contract) |
| 2 | `make lint INT=1` | clean — the `` `ifdef VOODOO_INT `` integer path elaborates with no `real`, no `$realtobits`, no `$rtoi`, no lint warnings |
| 3 | `make cosim INT=0` | builds `build/cosim_replay0` |
| 4 | `make cosim INT=1` | builds `build/cosim_replay1` |
| 5 | `make test` (implies `INT=0`) | **PIXEL-EXACT** on m1..m5 + unit tests (the gate; unchanged) |
| 6 | `make sim INT=1` then run m1..m5 | **NOT** expected pixel-exact — it will report mismatches vs gold; this is correct. Do **not** add `INT=1` to `test`. |
| 7 | `make rmse` (or §4.2 commands) | per-frame RMSE/PSNR; m1≈0, m2 small, m5 largest |
| 8 | `make cosim-lib INT=0` / `INT=1` | both build the QEMU static lib |

**Pixel-exact contract restated:** `make test` is an **INT=0-only** contract. The gold
model is float-only; INT=1 RTL is *intended* to differ. Keep `INT=1` out of `test`; judge
it by §4.

**Stale-object guard:** obj dirs are `$(INT)`-suffixed (§2), so toggling INT never reuses
stale generated C++. If you choose NOT to suffix, you MUST `make clean` between toggles.

---

## 6. RISKS — where integer precision deviates from float, and how to bound it

Ordered by expected RMSE impact. The float gold model is the *spec*, so every INT
deviation is measured against it.

1. **TMU perspective reciprocal `256/iterw` [UNSPEC-BY-DOC] — HIGHEST risk.**
   The float path divides in `double`; the integer reciprocal (SPEC §5.2) is a
   normalize + LUT (+ optional Newton). Truncation differences after `coord = iter*recip`
   flip texel selection on minified / steeply-perspective surfaces. **Bound:** size the
   reciprocal mantissa LUT for ≥18 result bits (≥ 14.18 ÷ 2.30 precision); add one Newton
   step; characterize `vd_recip_w` table contents directly against `make rmse` on **m5**
   (texture) and the glquake traces (perspective walls). Sweep mantissa-index width
   {7,8,9} and pick the smallest that drives m5 overall PSNR above the chosen gate
   (e.g. ≥ 40 dB). Localize with `max_abs`/`diffpix` per frame.

2. **`log2` LUT [UNSPEC-BY-DOC] (lodbase + lod_persp) — HIGH risk on mip selection.**
   A 1-LSB log2 error can move `ilod` by one level → a visibly different mip on whole
   regions. The float baseline keeps only the top 7 mantissa bits of an IEEE-754 double;
   the integer form (SPEC §6.2) uses CLZ + a mantissa LUT. **Bound:** match the integer
   part exactly via CLZ (deterministic), and characterize `vd_log2_mant` (128×8) against
   m5; verify the `>>1` (/2) for lodbase and the sign flip for lod_persp don't introduce
   off-by-one at level boundaries. Because `ilod = lod>>8` and lodbias/lodmin/lodmax snap
   to 1/4 (2 frac bits), small fractional log2 error below the top 2 frac bits is harmless
   unless it crosses an integer-level boundary — watch `diffpix` clustering at mip seams.

3. **Coverage rounding rule change (raster §4.3) — MEDIUM, mostly edge pixels.**
   The float path uses `round_coordinate` (round-to-nearest, ties **down**); the INT path
   uses the doc-true **top-left rule** (ceil left/top in, right/bottom out). These differ
   on boundary pixels of every triangle → thin 1-px seams in RMSE, concentrated on **m2**
   (Gouraud, lots of shared edges). **Bound:** this is a deliberate doc-fidelity choice —
   keep it. If a specific tie-break pixel must match the float baseline for some
   acceptance reason, the only lever is the rounding direction in SPEC §4.3 steps 2/3.
   Verify interiors are identical (RMSE should be dominated by edge pixels only — check
   `diffpix` ≪ N and `max_abs` small on m2 interiors).

4. **Affine `>>24` truncation direction — LOW, only negative coords.**
   `$rtoi` truncates toward zero; `>>>` floors for negatives. `vd_asr_trunc64` MUST
   truncate toward zero to match the float intent. **Bound:** unit-test `vd_asr_trunc64`
   against `(v<0)?-((-v)>>n):(v>>n)` for ± values; mismatch shows only on textures wrapping
   into negative s/t (m5).

5. **Slope DDA precision in the integer edge walk — LOW–MEDIUM.**
   The float path carries `dx/dy` as a `double`; the S27.4 integer slope (SPEC §4.3) has
   finite guard bits. For shallow edges (large `dy`), too-few guard bits drift `startX`
   over many rows. **Bound:** use the exact-DDA option (recompute X by integer mul/div in
   `vd_edge_x` per row at setup precision) rather than a precomputed truncated slope; or
   give the precomputed slope ≥ 8 guard bits. Validate on **m3** (full self-test has long
   thin triangles).

6. **Sum-of-squares width for lodbase — LOW (already exact).**
   Squares of s32 gradients fit in 128 bits exactly (SPEC §6.1); the float path rounds the
   products to 53 mantissa bits but `log2` keeps only the top 7 — so the **integer** path
   is actually *more* precise here. **Bound:** ensure the 128-bit accumulation doesn't
   overflow the chosen width (64b × 64b → 128b; use `logic [127:0]`), and feed `vd_log2_int`
   the full 128-bit value with `fracbits=64`.

**General bounding method:** `make rmse` per trace + per frame; treat **m1 ≈ 0** as a
sanity floor (fills don't touch the float sites), **m2** as the coverage probe, **m5** as
the TMU-arithmetic probe. Set CI gates with `ppm_rmse --min-psnr` once the
reciprocal/log2 LUTs are characterized; tighten by sweeping LUT widths. The two
[UNSPEC-BY-DOC] LUTs are the only blocks whose *contents* are tunable — everything else is
exact from the cited 3dfx docs, so any residual RMSE outside edge-pixel seams points back
at those two tables.

---

## 7. Implementation outcome & deviations from this plan (2026-06-14)

Implemented behind `make INT=1`; builds fully clean (lint+cosim, INT=0/1), `make test`
(INT=0) stays PIXEL-EXACT, and INT=1 is visually faithful to float — RMSE per trace
m1=0, m2=2.8, m3=3.5, m4=0, m5=2.4 (PSNR 37–∞ dB, <0.1% diffpix; residual is edge-pixel
float-vs-double ties, same class as MAME-VERIFICATION.md). Reaching that took three
corrections to the first cut, each isolated with a per-pixel int-vs-float probe
(`$display` in `tmu.sv` `S_LODCALC`, dumps joined on matching `s0/t0/w0`) and cross-checked
against the float baseline **and** SpinalVoodoo:

1. **Perspective coord: direct divide, not the reciprocal LUT.** The fixed-`R_SCALE`
   s32 reciprocal (`vd_recip_w`, §3.0/§5.2) collapsed to ~9 significant bits for large
   `iterw` → ~0.24% coord error → texel swim. Replaced with a direct 64-bit divide
   `coord = (iters<<8)/iterw` (signed `/` truncates toward zero == float `$rtoi`).
   `vd_recip_w`/`R_SCALE`/`RW_*` remain in `voodoo_pkg.sv` but are now unused (a future
   FPGA-efficient reciprocal could replace the divide).
2. **Coverage: round-nearest + center sampling, not top-left.** §4.3's top-left `ceil` +
   row-top sampling shifted spans ~1px (edge seams on m2, texture swim on m5). Changed to
   round-nearest-ties-down (`vd_round_s11_4 = (x+7)>>4`, replacing `vd_ceil_s11_4`, on both
   the span X and the `iy1/iy3` Y range) + row-CENTER sampling (`vd_edge_x` +8). This
   matches the float `round_coordinate` (MAME) **and** SpinalVoodoo center sampling — the
   top-left reading of GPG §4 was incorrect.
3. **Edge slope: full-precision DDA.** Slopes were `dx_s11.4 / dy_ROWS` truncated to 4
   fraction bits, drifting >1px over long edges (m5's ~480-row walls). Now `dX/dY` from the
   FULL S11.4 `dy` carried at `2^VD_SLOPE_FRAC` (=20) guard bits; `dxdy*_q` widened to s64.

Net: float lives only in `raster.sv`/`tmu.sv` under `` `ifndef VOODOO_INT ``. The INT path
uses integer divides (per-pixel perspective + per-row edge) — correct and synthesizable but
FPGA-costly, so M7 pipelining should revisit divider sharing.
