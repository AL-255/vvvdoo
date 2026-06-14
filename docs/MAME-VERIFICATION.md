# Bit-exactness verification vs real MAME

Goal (user directive): the RTL must produce images bit-identical to the MAME
Voodoo-1 model. This documents how that was verified and the one residual.

## Method

We did not instantiate MAME's full `device_t`/`emu.h` machinery. Instead we
took the high-value path: the golden model (`model/voodoo_gold.c`) was
instrumented to dump exact per-triangle float vertices and per-scanline span
endpoints, and a standalone harness reproduced MAME's actual `poly.h`
`render_triangle` span math (fetched from `mamedev/mame` master) plus MAME's
rasterizer-callback clip model, in the real `float` type MAME uses. All three
triangle traces (m2/m3/m4) were diffed at pixel-coverage level; the texture
path (`fast_log2`, `compute_lodbase`, `256.0/w` perspective) was diffed against
MAME `render.cpp` directly.

## Result

| Trace | vs real MAME | notes |
|---|---|---|
| m3 selftest_full (textured + perspective, 7 tris, 162616 px) | **IDENTICAL** | 0 span diffs, 0 pixel diffs |
| m4 pipeline (fog/chroma/stipple/alpha-mask, 16 tris, 177600 px) | **IDENTICAL** | 0 diffs |
| m2 gouraud (29 synthetic tris, ~154k px) | 2 pixels differ | exact-tie float/double, see below |

- **Texture math: bit-identical.** MAME's `fast_log2` (IEEE-double-bit form),
  `compute_lodbase`, and the `256.0/iterw` perspective divide are all `double`
  in MAME, and our ports match them exactly (same `>>45`/`>>32` shifts, `-1023`
  unbias, identical 128-entry `s_log2_table`, same operand order).
- **Pixel pipeline: bit-identical** (direct integer port of MAME's rgbaint ops).

## The residual: single-precision float vs Verilator

MAME's rasterizer is `poly_manager<float, ...>` — vertices `float(coord) *
(1.0f/16.0f)`, edge slopes and span endpoints in **single-precision float**.
**Verilator cannot do single-precision float**: it promotes `shortreal` to
`double` (verified — `$rtoi(16777217.0f)` returns `16777217`, i.e. the double
result, not float's `16777216`). So the RTL's coverage math runs in `double`
(Verilator `real`), and the golden model matches it in C `double` for a
consistent, testable `gold == RTL`.

`double` vs MAME's `float` round identically EXCEPT at exact N.5
`round_coordinate` ties (MAME rounds the .5 midpoint DOWN), where the
accumulated rounding residue lands on opposite sides of the tie. This produces:
- **0 divergent pixels** in real content (m3 textured selftest, m4 pipeline) —
  no span endpoint falls on an exact tie there.
- **2 divergent pixels** in the synthetic m2 fuzz trace (tri3 y=117: gold draws
  (46,117), MAME leaves background; tri24 y=182: MAME draws (51,182), gold
  background).

## Decision

**Accepted** (user). The RTL is byte-identical to MAME on real rendered content;
the residual is a Verilator single-precision limitation affecting only rare
exact-tie synthetic edges, not a design defect. Paths to 100% (DPI-C float
coverage, or soft-float in SV) were considered and deferred as not worth the
complexity for a ≤2-pixel synthetic-edge gap.

## Secondary (non-visible) divergence

m2 tri27 is offscreen (all-negative Y) with clipping OFF. MAME (no clip in the
callback) iterates negative scanlines and writes `destbase + scry*rowpixels`
with negative `scry`, spilling into the back-buffer region; our gold/RTL clamp
the scanline range to `[0,height)` and write nothing. This does not affect the
displayed front buffer (the m2/m3/m4 golden PPMs match). Well-behaved drivers
do not emit offscreen geometry with clipping off; only the synthetic m2 fuzz
triangle exercises it.
