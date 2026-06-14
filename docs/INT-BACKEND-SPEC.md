# Voodoo SST-1 — All-Integer (Fixed-Point) Arithmetic Backend SPEC

**Scope.** This document is the consolidated, exact fixed-point arithmetic spec for the
SST-1 RTL `VOODOO_INT` backend (built with `make INT=1`, which threads
`+define+VOODOO_INT` into every Verilator invocation). It defines every iterator
format, every divide, and the LOD path — integer bits / fraction bits / signedness /
rounding — each traced to its source document.

**Two laws govern this backend:**

1. **Doc fidelity.** Every fixed-point format below comes ONLY from the original 3dfx
   documents (SST-1 Spec r1.61, Glide Programming Guide 3.0) and the three 3dfx
   patents (US5831624A LOD, US5740343A / US5870102A texture-combine). **MAME / 86Box
   are NOT a source.** Items not pinned down by a 3dfx doc are flagged
   **[UNSPEC-BY-DOC]** and must be characterized empirically against the RMSE harness.

2. **The float path stays the bit-exact baseline.** The default build (`INT=0`) mirrors
   `model/voodoo_gold.c` (C `double`) bit-for-bit and is gated by `make test`
   (pixel-exact). The gold model has **no** integer concept, so the `INT=1` datapath is
   **deliberately NOT bit-exact** versus gold. `INT=1` correctness is judged by RMSE/PSNR
   vs the `INT=0` render (see `docs/INT-BACKEND-PLAN.md` §4), never by `make test`.

Provenance tags used throughout:
- **[DOC]** — stated verbatim in a cited 3dfx doc (page/section/figure given).
- **[FORCED]** — the unique integer formulation determined by [DOC] formats + the [DOC]
  coverage / clamp rules (the micro-recurrence itself is not printed, but only one
  integer form satisfies the stated rule).
- **[UNSPEC-BY-DOC]** — no original 3dfx doc pins the numeric content; must be
  characterized against the harness. These are the ONLY blocks that are not exact.

Source documents (absolute paths):
- `/home/yukidama/github/vvvdoo/vvvdoo-refs/01-specs-regs/Voodoo1_SST-1_Spec_r1.61_199912.pdf`
- `/home/yukidama/github/vvvdoo/vvvdoo-refs/02-glide-driver/Glide_Programming_Guide_3.0_199806.pdf`
- US5831624A (LOD dither/compute), US5740343A & US5870102A (texture-combine) — figures cited inline.

---

## 1. Vertex coordinate format

| Quantity | Format | Bits | Signed | Resolution | Source |
|---|---|---|---|---|---|
| `vertexAx/Ay/Bx/By/Cx/Cy` | **S11.4** (a.k.a. "12.4 two's-complement") | 16 | yes (two's-comp) | 1/16 px = 0.0625 | **[DOC]** SST-1 §5.2 p.24–25; reg table p.18–19 |

- 12 integer bits **including sign** + 4 fraction bits. Pixel **center = integer-aligned**
  coordinate (`x.0000`); sub-pixel grid is 1/16. Subpixel resolution ".4 × .4" — **[DOC]**
  SST-1 p.2 Features.
- `fvertex*` (IEEE-754 binary32) registers are auto-converted to the same internal S11.4
  — **[DOC]** SST-1 §5.2 p.24. (RTL already does this in `rtl/float_conv.sv` with
  `fixedbits=4`; that module is integer and reused unchanged.)
- Edge labels — **[DOC]** §5.2 p.24: vertices A,B,C; **AB,BC = minor edges, AC = major
  edge**. Area is computed after sorting A,B,C so `A.y ≤ B.y ≤ C.y` — **[DOC]** §5.15 p.30.

RTL representation: keep the three vertices as the existing `logic signed [15:0]`
(`ax_q..cy_q` in `rtl/raster.sv`). The S11.4 → S27.4 widening for the walk is exact
(`{{12{v[15]}}, v}` style) — `/16` is exact in this domain, so no precision is lost vs the
float verts.

---

## 2. Iterated-parameter fixed-point formats (the DDA accumulators)

All `start*` = parameter value at **vertex A** (**[DOC]** §5.3–§5.6). All `d?dX`/`d?dY` are
**per-1-pixel-step** signed two's-complement deltas. Step rule — **[DOC]** §5.7/§5.11:
- move **+1 in X** (left→right): `param += d?dX`; move −X: `param -= d?dX`.
- move **+1 in Y**: `param += d?dY`; move −Y: `param -= d?dY`.

| Param | Register | Reg bits | Format (int.frac) | Signed | Internal accumulator (RTL) | Source |
|---|---|---|---|---|---|---|
| R,G,B,A start | startR/G/B/A | 23:0 | **12.12** | two's-comp | `signed [31:0]` carried in `[63:0]` | **[DOC]** §5.3 p.26 |
| R,G,B,A slope | dRdX…dAdY | 23:0 | **12.12** | two's-comp | — | **[DOC]** §5.7/§5.11 |
| Z (depth) start | startZ | 31:0 | **20.12** | two's-comp | `signed [31:0]` in `[63:0]` | **[DOC]** §5.4 p.26 |
| Z slope | dZdX/dZdY | 31:0 | **20.12** | two's-comp | — | **[DOC]** §5.8/§5.12 |
| S/W, T/W start | startS/startT | 31:0 | **14.18** | two's-comp | `signed [63:0]` | **[DOC]** §5.5 p.26 |
| S/W, T/W slope | dSdX/dTdX/dSdY/dTdY | 31:0 | **14.18** | two's-comp | — | **[DOC]** §5.9/§5.13 |
| 1/W start | startW | 31:0 | **2.30** | two's-comp | `signed [63:0]` | **[DOC]** §5.6 p.27 |
| 1/W slope | dWdX/dWdY | 31:0 | **2.30** | two's-comp | — | **[DOC]** §5.10/§5.14 |
| Triangle area | triangleCMD | bit 31 (sign only) | sign of AREA | signed | — | **[DOC]** §5.15 p.30 |

Important [DOC] semantics that the integer path must honor:
- **"W" stored everywhere is actually 1/W** — **[DOC]** §5.6 p.27. **S,T are stored as S/W,
  T/W** (perspective space) — **[DOC]** §5.5 p.26 reg labels "S/W"/"T/W".
- **RGBA iterators have rounding + clamping in hardware** — **[DOC]** SST-1 p.13 ("RGBA
  iterators with rounding and clamping"). Color delivered to the pixel pipe = the
  **integer part** of the 12.12 accumulator, clamped to [0,255]. (RTL: the existing
  `clamp_argbf` in `rtl/pixel_pipe.sv` already does the [0,255] clamp on the integer part;
  unchanged.)
- **Internal accumulator width.** The RTL keeps 32-bit channels (R,G,B,A,Z) sign-extended
  in 64-bit lanes and S/T/W in full 64-bit lanes (`ch_start/ch_dx/ch_dy[9]`,
  `rowp/pixp[9]` in `rtl/raster.sv`). Low-32 truncation of mod-2⁶⁴ arithmetic is exactly
  mod-2³² arithmetic, so the seeding multiply (`mul_p = mul_a*mul_b`) and per-step adds are
  **already exact two's-complement** and are reused **unchanged** by the INT path. The
  iterator DDA is therefore NOT a float site — only the **coverage** decision and the
  **TMU divide/LOD** are.

### 2.1 Depth value derivation

- **Z-buffer (fbzMode bit3 = 0):** depth source = iterated Z (20.12). Stored depth = the
  **16-bit integer portion** of iterated 1/z → `depth16 = clamp(Z_acc[27:12], 0..0xFFFF)`
  (the 16 integer bits above the 12 fraction bits). **[DOC]** GPG p.69 "Fixed Point z
  Buffering"; SST-1 §5.19.1 p.46 (compare); fbzMode bit16 may add `zaColor[15:0]` as a
  depth bias. (RTL `rtl/pixel_pipe.sv` `clamped_zf` already implements `asr32(z,12)` +
  clamp; integer, unchanged.)
- **W-buffer (fbzMode bit3 = 1):** depth = inverse of the normalized 1/W iterator encoded
  as a **16-bit float: 4-bit exponent + 12-bit mantissa, unsigned, hidden leading 1**,
  value = `1.mantissa × 2^exponent`; `0x0000 → 1.0`, `0xFFFF → 65528.0`. **[DOC]** SST-1
  §5.19 p.44–45; GPG §11 Table 11.1 p.132. The 1/W is inverted before encoding "so the
  same depth comparisons work as a z-buffer" (SST-1 p.45). (RTL `rtl/pixel_pipe.sv`
  `wfloatf` already implements this with a CLZ + exponent + mantissa pack — integer,
  synthesizable, **and is the idiom the new `log2` / reciprocal helpers must mirror**.)
- **Fog index:** MSBs of the normalized float 1/W index the 64-entry fogTable; next 8 bits
  blend adjacent entries. **[DOC]** SST-1 §5.17 p.38. (RTL `apply_fogf` — integer,
  unchanged.)

---

## 3. Triangle area & orientation

**[DOC]** SST-1 §5.15 p.30. After sorting `A.y ≤ B.y ≤ C.y`:

```
dxAB = A.x - B.x ;  dyAB = A.y - B.y          // all in S11.4 (4 frac bits)
dxBC = B.x - C.x ;  dyBC = B.y - C.y
AREA = ((dxAB * dyBC) - (dxBC * dyAB)) / 2     // products carry 8 frac bits; /2 = >>1
```

- **Only AREA's sign bit is used** (triangleCMD bit31; bits 30:0 ignored). `bit31=0 ⇒
  CCW/positive`, `bit31=1 ⇒ CW/negative`. Orientation↔sign also depends on origin — **[DOC]**
  GPG Table 4.2 p.45 (LOWERLEFT: CW→neg, CCW→pos; UPPERLEFT: CW→pos, CCW→neg).
- **HANG CAVEAT [DOC]** §5.15.1.1 p.30: if the submitted triangleCMD sign ≠ the sign
  implied by the vertices, FBI hangs forever. The sign you compute must equal the sign you
  submit.

**RTL note (matches existing behavior):** the current raster is **winding-agnostic** — it
swaps `start/stop` so `left ≤ right` and ignores the submitted sign (see `raster.sv`
header + `sign_q` left unused). The INT path keeps this: `AREA == 0 ⇒ zero pixels` is the
only area-derived behavior the front end needs, and the swap subsumes orientation. The
explicit sign compare/ hang is a host-side (cmd_dispatch / driver) contract, not a
front-end arithmetic site.

---

## 4. Coverage / pixel-fill convention (the integer edge walk)

### 4.1 Fill rule — **[DOC]** GPG §4 p.31–32

1. **Zero-area triangles render zero pixels.**
2. **Center sampling:** "a pixel is rendered iff its center lies within the triangle." The
   sample point is the integer pixel center `(x, y)` (= `x.0000` in S11.4).
3. **Top-left rule:** "Left edges are in; right edges are out. Horizontal edges with the
   smaller y value are in; those with a larger y value are out." Note "top" = **smaller
   y**, independent of the user origin flag.

### 4.2 Clip rectangle — **[DOC]** SST-1 §5.21 p.53; GPG p.30

- `clipLeftRight`: bits 9:0 = right (unsigned), bits 25:16 = left. `clipLowYHighY`: bits
  9:0 = highY, bits 25:16 = lowY. All **unsigned 10-bit** pixel coords.
- **Inclusive of left/lowY, EXCLUSIVE of right/highY.** Clip Y origin is **always
  top-of-screen** regardless of fbzMode bit17. Enable via fbzMode bit0. (RTL already
  clips `[cl,cr)` right-exclusive and `[ct,cb)` — `raster.sv` lines 166–170, 327–328 —
  this matches and is reused.)

### 4.3 Integer span derivation — **[FORCED]** by the S11.4 format + the top-left rule

The internal edge-walk recurrence is **not printed** in the SST-1 spec ("automatic", spec
p.13). The following is the unique integer form forced by the stated S11.4 vertex format
and the GPG top-left/center-sampling rule. **This is the INT coverage spec.** It differs
intentionally from the float path's `round_coordinate` (round-to-nearest, ties down) —
that is the float baseline; the INT rule is the doc-true top-left rule.

For an edge from `(x0,y0)` to `(x1,y1)` in S11.4, the edge X at integer row `y` is a
two's-complement DDA: `Xedge += slope` per +1 in Y, `slope = (x1-x0)/(y1-y0)` carried with
≥ 4 fraction bits (same .4 grid as X; widen to S27.4 internally to retain DDA precision
for shallow edges). Then:

1. **Row inclusion (top-in / bottom-out):** include row `y` iff
   `(y<<4) ≥ yTop_S11.4` **and** `(y<<4) < yBottom_S11.4`. (yTop/yBottom = the two edge
   endpoints' Y.)
2. **startX (left edge, inclusive):** a center exactly on a left edge is **inside**, so
   round the left-edge X **up** to the next integer center:
   `startX = ceil(Xleft) = (Xleft_S11.4 + 0x0F) >> 4`.
3. **stopX (right edge, exclusive):** a center exactly on a right edge is **outside**, so
   the last filled pixel is `ceil(Xright) - 1`. Fill the half-open span `[startX,
   ceil(Xright)-1]`, i.e. centers with `Xleft ≤ x < Xright`, left-in/right-out.
4. **Clip:** intersect `[startX, stopX]` with `[clipLeft, clipRight-1]`; row with
   `[clipLowY, clipHighY-1]`.
5. **Iterator seeding:** seed at vertex-A `start*`, step by integer multiples of `d?dY`
   (down the major edge to row `y`) then `d?dX` (across to `startX`) using §2's
   add/subtract rule. With subpixel correction (`fbzColorPath bit26=1`) the start params
   are pre-corrected for A's .4 fraction (see §6.3). **RTL reuses the existing exact
   integer seeding** (`mul_p` + `rowp/pixp`); only the `startX/stopX/row` *bounds* change
   from the float `round_coordinate` form to the §4.3 `ceil`/top-left form.

> **Validation lever.** If a tie-break pixel disagrees under RMSE, the only knob is the
> rounding direction in steps 2/3 — keep left/top "in" via `ceil`, right/bottom "out".

---

## 5. Divides & reciprocals

### 5.1 Front-end (raster) — **no divides except area /2**

**[DOC]** §5.15: `AREA = (…)/2` is a trivial arithmetic right-shift, and **only the sign
is consumed** (bits 30:0 ignored), so magnitude precision is irrelevant. The slopes
`d?dX/d?dY` arrive **pre-divided by the host/driver** — there is **no on-chip
area-reciprocal in the SST-1 triangle front-end** (**[DOC]** GPG p.5/p.43: the host
"calculates the associated gradients"; the area "must be computed anyway"). The front end
therefore needs only exact integer add/subtract DDA — which the RTL already has.

### 5.2 TMU per-pixel perspective divide — **[DOC]** that it exists; **[UNSPEC-BY-DOC]** width

**[DOC]** SST-1 p.13: "During each iteration of span/trapezoid walking, a division is
performed by 1/W." Per-pixel:

```
iterw = (signed) 1/W iterator                 // 2.30 format, carried s64
if iterw == 0: iterw = 1                       // divide-by-zero guard (substitute before use)
if tpersp_st (textureMode[0]):
    recip   = 256 / iterw                       // RECIPROCAL UNIT — [UNSPEC-BY-DOC], scaled ×256
    coord_s = (S/W_iter) * recip                // signed; format per §7
    coord_t = (T/W_iter) * recip
else (affine):
    coord_s = (S/W_iter) >> 24                  // truncate toward zero (see note)
    coord_t = (T/W_iter) >> 24
negw = (iterw < 0)                              // used by tclampw
tclampw (textureMode[3]) && negw  ->  coord_s = coord_t = 0   // [DOC] §5.50 p.64
```

- **Reciprocal width is [UNSPEC-BY-DOC].** No 3dfx doc publishes the texture reciprocal's
  table/mantissa/exponent. The ONLY documented 1/W table is the **fog** unit (64-entry,
  6-bit FP index of 1/W — SST-1 §FOG p.5), a separate block; it is the only hint that
  3dfx used a ~6-bit-exponent/mantissa float for 1/W. Implement a true integer reciprocal:
  normalize `|iterw|` to `1.m·2^e` (leading-one detect over the 32-bit fraction →
  exponent), `recip_m = recip_tab[m_hi]` (optionally one Newton step), shift by `e`
  (adjusted for the ×256 scale), sign from `iterw`. **Size for ≥ the precision implied by
  14.18 ÷ 2.30 → ≥ 18 significant result bits**; characterize the table against the RMSE
  harness. **Do NOT lift MAME's `double 256.0/iterw`.**
- **Affine `>>24` rounding:** the float baseline truncates toward zero (`$rtoi`). For the
  INT path, replicate truncate-toward-zero (NOT `>>>` floor) so negative coords match the
  baseline's intent: `coord = (iter < 0) ? -((-iter) >> 24) : (iter >> 24)`.

### 5.3 Subpixel correction — **[DOC]** §5.16 bit26 p.31/35, §9.4 p.84

When `fbzColorPath bit26 = 1`, setup corrects the incoming `start{RGBA,Z,S,T,W}` for the
.4 fraction of the starting `(x,y)`, as the params are read from the FIFO:

```
start' = start + (dParam/dX)·fracX + (dParam/dY)·fracY      // exact integer FMA, native width
```

`fracX/fracY` = 4-bit fractions of the snapped vertex. **Caveat [DOC]** §9.4/§5.16 p.35:
correction mutates start registers in place; each triangle must re-send all start params
or they get corrected twice. **RTL note:** the existing pipeline applies this upstream in
`cmd_dispatch` before launch (see `raster.sv` header line 31–32); it is integer already
and is NOT a `VOODOO_INT` site.

### 5.4 Per-pixel S,T after divide

`S = (S/W)/(1/W)`, `T = (T/W)/(1/W)` is the only per-pixel divide (folded into §5.2's
`recip` multiply). Output S,T feed the texel addressing (§7).

---

## 6. LOD computation — per US5831624A

LOD combines (1) a per-triangle base term from the S/W,T/W gradients and (2) a per-pixel
perspective term from 1/W, then bias + clamp + (optional) dither.

### 6.1 Term definitions

**[DOC]** US5831624A col 8 eq.(1): texels-per-pixel = `2^(2·LOD)`; GPG p.96 restates "LOD n
when a pixel covers ~2^(2n) texels", so `LOD = ½·log2(texels-per-pixel)`.

- **Per-triangle base ("lodbase"):**
  ```
  texdx = (S/W_dx)^2 + (T/W_dx)^2        // sum of squares of per-X gradients (exact integer)
  texdy = (S/W_dy)^2 + (T/W_dy)^2        // gradients are s32 in 14.18 -> squares fit ~128b
  lodbase = log2( max(texdx, texdy) , fracbits=64 ) / 2   // /2 truncates toward zero
  ```
  Squares of the S/T gradients are **exact integers** (≤ ~128-bit); take the max, feed the
  integer `log2`. `/2` is a signed integer divide truncating toward zero. **[DOC]** for the
  equation/structure; the log2 table is **[UNSPEC-BY-DOC]** (§6.2).
- **Per-pixel perspective term:**
  ```
  lod_persp = - log2( iterw , fracbits=32 )    // iterw = 1/W (2.30); large 1/W (near) -> negative LOD
  ```
  0 when affine (`textureMode[0]=0`).

### 6.2 The integer `log2` — **[UNSPEC-BY-DOC]** table contents

US5831624A documents the LOD-fraction **dither** in detail (§6.5) but does **NOT** publish a
log2 mantissa table or exponent extraction; nor does the SST-1 spec / Glide guide.
Algorithm shape (output **signed, 8 fraction bits** — the "24.8" carrier):

```
log2(value, fracbits):                          // value >= 0 (negative -> 0)
    exp  = floor_log2(value) - fracbits          // integer part of log2, de-scaled
    frac = LOG2_MANT_TAB[ mantissa_index ]       // 8-bit fractional log2 of the leading mantissa
    return (exp << 8) | frac
```

- Implement `floor_log2` as an **integer leading-one detector** (CLZ over the fixed-point
  operand → bit position) — exactly the CLZ idiom already used by `wfloatf` in
  `rtl/pixel_pipe.sv`. `mantissa_index` = the bits just below the leading one (e.g. 7 bits
  → 128-entry LUT). `LOG2_MANT_TAB[i] = round(256·log2(1.i))`, monotone 0→255.
- **Provenance flag:** the 128×8 `log2tab` currently in `rtl/tmu.sv` (lines 58–79) and
  `s_log2_table` in `voodoo_gold.c` (lines 622–631) are **MAME-derived, NOT a 3dfx
  document** — they are the FLOAT baseline only. For `VOODOO_INT`, the LUT width/contents
  are a free parameter to be characterized against the RMSE harness; a 128×8 LUT keyed on
  the 7 mantissa bits reproduces the reference precision and is the recommended start.

### 6.3 Combine / bias / clamp / level select — **[DOC]** SST-1 §5.51 p.66

```
lod = lod_persp + lodbase + lodbias            // all signed x.8
lod = clamp(lod, lodmin, lodmax)               // clamp in x.8; max level effectively 8.0
ilod = lod >> 8                                 // integer mip level (lod >= lodmin >= 0)
ilod = ilod + ((~lodmask >> ilod) & 1)          // skip absent levels in split textures
if ilod > 8: ilod = 8                           // 256x256 base has 9 levels 0..8
```

Register → internal x.8 (registers carry 2 frac bits; shift to reach 8 frac bits):
```
lodmin  = unsigned(tLOD[5:0])  << 6             // 4.2 unsigned  -> x.8
lodmax  = unsigned(tLOD[11:6]) << 6             // 4.2 unsigned  -> x.8
lodbias = {sext, tLOD[17:12], 2'b00} << 4       // 4.2 signed    -> x.8
lodmask = tLOD[19] ? (tLOD[18] ? 9'h0AA : 9'h155) : 9'h1FF   // tsplit ? (odd?odd:even) : all
```

**[DOC]** §5.51 p.66: "lodbias is added to the calculated LOD, then clamped to [lodmin,
min(8.0, lodmax)]." GPG p.96 confirms bias range [−8..7.75] snapped to 1/4 (the 4.2
signed). **RTL note:** the LOD-resolve block in `rtl/tmu.sv` (lines 303–322), the
`lodmin/lodmax/lodbias` shifts (lines 124–127), and the `lodmask`/`ilod` math are
**already integer and already match this** — they are reused unchanged by `VOODOO_INT`.
Only the two *inputs* `lodbase_q` and `lod_persp_q` change from float to integer.

### 6.4 Format reconciliation (the subtle part)

- **US5831624A** dither unit (Fig 5/6/9): LOD enters as **7.2** (7 int + 2 frac); a 0.2
  dither is added; result 8.2 → clamp → 8-bit integer level. So the **patent-documented
  fraction granularity is 2 bits** — matching the **4.2** lodmin/lodmax/lodbias registers.
- The **internal arithmetic** carries **8 fraction bits** (x.8) because `log2` emits 8 frac
  bits and `ilod = LOD>>8`. The low 6 frac bits sit below the documented 1/4-LOD
  granularity and exist only inside the silicon's log2/divide path. **No original 3dfx doc
  states the 8-bit internal fraction** — it is the carrier the RTL uses and is flagged as
  inferred. (For `VOODOO_INT` we keep the x.8 carrier to match the existing integer
  LOD-resolve block.)
- **LOD fraction for trilinear/dither** = the **top 2 bits of the fraction** (bits [7:6] of
  the x.8 LOD), per the patent's 7.2 / Fig 9 "LOD FRACTION 00/01/10/11".

### 6.5 LOD dither hardware — **[DOC]** US5831624A Fig 5/6/9; SST-1 textureMode[4] `tloddither`

Combinational, keyed on low pixel coords `x[0]`,`y[0]`; adds an average of **3/8 (.375)**
to LOD (SST-1 §5.50 p.64). Fig 5 (preferred, square dither):
```
d_msb   = x[0] XOR y[0]
dither2 = { d_msb, y[0] }                       // 2-bit, weight 0.2
lod_dithered_8_2 = lod_7_2 + dither2            // 7.2 + 0.2 -> 8.2
level = clamp(lod_dithered, lodmin, lodmax) integer 8 bits
```
Fig 9 decision table (LODfrac vs dither → pick lower(L)/higher(H) mip):
```
            LODfrac=00 01 10 11
dither=00:      L   L  L  L
dither=01:      L   L  L  H
dither=10:      L   L  H  H
dither=11:      L   H  H  H
```
(Fig 6 alt: programmable ROM dither matrix indexed by `{x[0],y[0]}` + 2-bit comparator.)
**Current scope note:** the present TMU runs single-level point/bilinear (no trilinear /
LOD dither yet — `tex_combine` is called with `lodfrac=0`). `tloddither` and trilinear are
a follow-on; the formats above are specified so they slot in without rework.

---

## 7. Texel S/T fixed-point → texture-RAM address + bilinear fraction

After the divide, `coord_s/coord_t` are signed and scaled so **8 fraction bits** sit at the
bottom after the per-level shift. Texel centers are half-texel-offset (**[DOC]** GPG Table
9.1 p.86–87: first texel center at 0.5 → the −0.5 bias in bilinear).

### 7.1 Per-level masks — **[DOC]** §5.51 p.66 (tLOD aspect bits)
```
// tLOD[20]=lod_s_is_wider, tLOD[22:21]=lod_aspect (00 sq,01 2:1,10 4:1,11 8:1)
if lod_s_is_wider: wmask=0xFF;               hmask=0xFF >> aspect
else:              wmask=0xFF >> aspect;     hmask=0xFF
smax = wmask >> ilod ;  tmax = hmask >> ilod
```
(RTL `rtl/tmu.sv` lines 116–135, 321–322 — already integer, reused.)

### 7.2 Point-sampled addressing (min/mag filter = 0)
```
sh = ilod + 8
ss = coord_s >>> sh ;  tt = coord_t >>> sh                  // arithmetic shift, truncate to integer texel
if tclamps (texmode[6]): ss = clamp(ss, 0, smax)
if tclampt (texmode[7]): tt = clamp(tt, 0, tmax)
ss &= smax ; tt &= tmax                                      // power-of-2 wrap
texel_index = tt*(smax+1) + ss
```

### 7.3 Bilinear addressing + fraction bits (min/mag filter = 1)
```
ss = coord_s >>> ilod ;  tt = coord_t >>> ilod              // keep 8 frac bits
ss -= 0x80 ; tt -= 0x80                                      // -0.5 texel (centers half-texel; [DOC] GPG Tbl 9.1)
sfrac = ss[7:0] & 0xF0 ; tfrac = tt[7:0] & 0xF0             // top 4 of 8 frac bits -> 16 sub-texel levels
ss >>= 8 ; tt >>= 8                                          // integer texel of base corner
s1 = ss+1 ; t1 = tt+1
if tclamps: if ss<0 {ss=s1=0} elif ss>=smax {ss=s1=smax}
if tclampt: if tt<0 {tt=t1=0} elif tt>=tmax {tt=t1=tmax}
ss&=smax ; s1&=smax ; tt&=tmax ; t1&=tmax
idx00=tt*(smax+1)+ss ; idx10=...+s1 ; idx01=t1*(smax+1)+ss ; idx11=...+s1
```
- **Fraction precision:** addressing keeps 8 frac bits; bilinear weighting uses only the
  **top 4** (`& 0xF0`). The 4-bit width is **[UNSPEC-BY-DOC]** (conceptually US5831624A Fig
  8D U_FRAC/V_FRAC) — flagged inferred; matches the existing integer path.

### 7.4 Texture-RAM byte/word address — **[DOC]** §5.53 p.68, §5.50 p.63
```
bpt = (tformat >= 8) ? 2 : 1          // formats 0..5 = 8-bit; 8..14 = 16-bit  [DOC] §5.50 table p.63
if bpt==1: byte_addr = (texbase + texel_index) & TEX_MASK
           word_addr = byte_addr >> 1 ; byte_hi = byte_addr[0]
else:      byte_addr = (texbase + 2*texel_index) & TEX_MASK & ~1
           word_addr = byte_addr >> 1 ; byte_hi = 0
```
Texel-format expansion to ARGB8888 is given verbatim in SST-1 §5.50 table p.63 (565,
3-3-2, 1555, 4444, A8, I8, AI44, …). **RTL note:** §7.1–§7.4 are **entirely integer
already** in `rtl/tmu.sv` (`texel_expand`, corner address gen, bilinear blend) and are
**reused unchanged**. The ONLY change in the TMU under `VOODOO_INT` is replacing the float
producers of `coord_s_q/coord_t_q/lod_persp_q/lodbase_q` (the divide + log2).

---

## 8. Texture-combine / bilinear / trilinear blend — **[DOC]** US5740343A / US5870102A Fig 7

Integer datapath, per channel: **9-bit signed × 9-bit unsigned multiply, take 9 MSBs,
+local, clamp 0–255, optional invert** — exactly the existing `tex_combine` in
`rtl/tmu.sv` (lines 236–294) and the bilinear weights in lines 355–367. These are
**already integer and bit-exact to the figures' bit-widths** and are **NOT** `VOODOO_INT`
sites. Documented here for completeness:

```
base = zero_other ? 0 : other ; if sub_clocal: base -= local      // 9-bit signed
f = mux{0, c_local, a_other, a_local, f(LOD), frac(LOD)}           // 8-bit
if !reverse_blend: f ^= 0xFF ; f += 1                               // -> 256-f when reversed
prod = base(9b signed) * f(9b uns) ; prod >>>= 8                    // 9 MSBs
out  = clamp(prod + (add_clocal? local : 0), 0, 255)
if invert_output: out ^= 0xFF
```
Bilinear (4-tap): `w?? = ((256∓sfrac)*(256∓tfrac))>>8`, `out = Σ c?? · w?? >> 8`
(US5831624A Fig 8D weighting). Trilinear (follow-on) blends two adjacent-level bilinear
results by `F_blend = frac(LOD)` with REVERSE_BLEND giving `1−frac(LOD)` for the
odd/even-parity level (US5740343A col 9).

---

## 9. INT-vs-FLOAT divergence summary (what is and is not bit-exact)

| Site | FLOAT baseline (INT=0, gold-exact) | INT=1 form | Same result? |
|---|---|---|---|
| Iterator DDA (RGBA/Z/S/T/W) | exact two's-comp (already integer) | identical | **yes** |
| RGBA/Z clamp, fog, blend, alpha | integer (`pixel_pipe.sv`) | identical | **yes** |
| texel expand / address / bilinear / combine | integer (`tmu.sv`) | identical | **yes** |
| Coverage rounding (startX/stopX/rows) | `round_coordinate` (nearest, ties down) | `ceil`/top-left (§4.3) | **NO (by design)** |
| TMU perspective `256/iterw` | C `double` divide | integer reciprocal (§5.2) | **NO (by design)** |
| TMU affine `>>24` | `$rtoi` truncate | integer truncate-toward-zero | yes if truncation matches |
| `log2` (lodbase, lod_persp) | IEEE-754 double bit-pun | integer CLZ + LUT (§6.2) | **NO (by design)** |

The three "NO (by design)" rows are exactly why `INT=1` is judged by RMSE, not `make
test`. The expected RMSE profile: ~0 on flat fills (m1), small on Gouraud (m2), texture
error concentrated on perspective walls / minified surfaces (m5) where the reciprocal/log2
approximations bite. See `docs/INT-BACKEND-PLAN.md` §4 (RMSE harness) and §6 (risks).
