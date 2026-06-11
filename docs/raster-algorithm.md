# vvvdoo triangle rasterization rule (normative)

This document defines the EXACT integer rasterization algorithm implemented by
both the golden model (`model/voodoo_gold.c`) and the RTL (`rtl/raster.sv`).
The two must agree bit-for-bit. The rule is adopted from 86Box/PCem's Voodoo
renderer (`vvvdoo-refs/03-emulators/86box_video/vid_voodoo_render.c`,
`voodoo_triangle()` 1446–1596 / `voodoo_half_triangle()` 671–1444), which was
black-box validated against real SST-1 silicon; its odd constants (the
`+0x7000` bias, the −1-pixel trailing-edge pullback, `(y+7)>>4`) are
reverse-engineering artifacts and are NORMATIVE here. Where MAME differs it is
noted; we follow 86Box except where stated.

Notation: all values are two's-complement integers. `>>` on a signed value is
an ARITHMETIC shift. `/` is division TRUNCATING TOWARD ZERO (C semantics).
Coordinates named with subpixels are s12.4 (1/16-pixel units). "mod 2^N"
means the result is truncated to the low N bits and reinterpreted as signed
(C: cast through uintN_t; SV: natural width truncation).

## 1. Inputs

```
Ax, Ay, Bx, By, Cx, Cy   s16, 12.4 subpixel coords (from vertex regs, raw)
sign                     1 bit = bit 31 of the data written to triangleCMD or
                         ftriangleCMD. 1 means signed area is negative, i.e.
                         the long edge A->C is the RIGHT edge of the triangle.
start{R,G,B,A}, d*dX, d*dY   s32 (12.12 sign-extended from 24 bits)
startZ, dZdX, dZdY           s32 (20.12)
startW, dWdX, dWdY           s64 (16.32)   [FBI W; also TMU0 W]
startS/T, dS/TdX/Y           s64 (14.18 stored <<14)
clip_left, clip_right, clip_top, clip_bottom   effective clip rect, pixels;
                         left/top inclusive, right/bottom exclusive.
                         When fbzMode bit0 = 0 the caller supplies
                         {0, width, 0, height}; the rasterizer ALWAYS clips
                         to this rect (deviation from 86Box, see CONTRACTS §9).
subpixel_adjust          fbzColorPath bit 26
```

The driver contract is `Ay <= By <= Cy` with a consistent `sign`, but the
algorithm below is a TOTAL function: any input produces a deterministic
(possibly empty) pixel set. Implementations must NOT add ordering checks or
degenerate-triangle rejects — both sides compute the same formulas, always.

## 2. Setup

```
slope(dx_sub, dy_sub):                # both s13.4 differences (17-bit)
    if dy_sub == 0: return 0
    return trunc32( (sext64(dx_sub) << 16) / dy_sub )   # s15.16, trunc toward 0

dxAB = slope(Bx - Ax, By - Ay)
dxAC = slope(Cx - Ax, Cy - Ay)
dxBC = slope(Cx - Bx, Cy - By)

ystart0 = (Ay + 7) >> 4               # first candidate scanline (unclipped)
yend0   = (Cy + 7) >> 4               # exclusive
ystart  = max(ystart0, clip_top)
yend    = min(yend0,  clip_bottom)

pA = (Ax + 7) >> 4                    # vertex-A reference pixel column
                                      # (== ((Ax<<12) + 0x7000) >> 16)
```

Y coverage rule this encodes: scanline `y` is a candidate iff
`Ay <= 16*y + 8 < Cy` (top tie INcluded, bottom tie EXcluded). Both 86Box and
MAME agree on this.

### Subpixel start-value adjustment (fbzColorPath bit 26)

Applied ONCE per triangle to the start values, BEFORE walking (in RTL this is
done by cmd_dispatch; in gold at triangle launch):

```
fx = Ax & 15;  dxs = 8 - fx;  if (fx > 8) dxs += 16    # dxs in [0,15]
fy = Ay & 15;  dys = 8 - fy;  if (fy > 8) dys += 16
for each iterated parameter P (R,G,B,A,Z,W, S0,T0,W0):
    startP = startP + ((dxs * dPdX + dys * dPdY) >> 4)   # full width, mod 2^32/2^64
```

(86Box's mod-16 form, NOT MAME's signed −7..+8 form; it is the one consistent
with the `(v+7)>>4` reference pixel used everywhere here.)

## 3. Iterated parameter values (absolute form)

The value of parameter P at pixel `(x, y)` (post-adjustment startP):

```
P(x, y) = startP + (x - pA) * dPdX + (y - ystart0) * dPdY
```

computed mod 2^32 for R,G,B,A,Z and mod 2^64 for W,S,T. `ystart0` is the
UNCLIPPED first scanline. Implementations may use any incremental scheme
(row accumulator + per-pixel step) PROVIDED the result is bit-identical to
this formula at every emitted pixel. (Two's-complement add/mul wrap makes the
incremental and absolute forms exactly equal; in C use unsigned arithmetic
internally to avoid signed-overflow UB.)

## 4. Per-scanline walk

For `y` from `ystart` to `yend - 1` (skip everything if `ystart >= yend`):

```
ys = (y << 4) + 8                            # row center, 12.4

xMaj = trunc32( (Ax << 12) + asr4(dxAC * (ys - Ay)) )      # s16.16 pixels
if (ys < By): xMin = trunc32( (Bx? no -> A) ... )           # minor edge:
if (ys < By): xMin = trunc32( (Ax << 12) + asr4(dxAB * (ys - Ay)) )
else:         xMin = trunc32( (Bx << 12) + asr4(dxBC * (ys - By)) )
```

`asr4(v)` = arithmetic shift right by 4 of the FULL product (the product
`s15.16 * s13.4` needs ≥49 bits before the shift; compute in 64-bit then
truncate the sum to 32 bits). Note: at `ys == By` exactly, the BC edge is used
(both 86Box and MAME agree).

Span endpoints — one whole pixel (0x10000) is subtracted from the TRAILING
edge, then both ends are rounded by `floor(v + 0x7000)`:

```
if sign == 0:                                # AC is LEFT edge, walk +x
    first = (xMaj + 0x7000) >> 16
    last  = (xMin - 0x10000 + 0x7000) >> 16
    step  = +1
else:                                        # AC is RIGHT edge, walk -x
    first = (xMaj - 0x10000 + 0x7000) >> 16
    last  = (xMin + 0x7000) >> 16
    step  = -1
```

(The bias is 0x7000 = 7/16 of a pixel, NOT 1/2 — normative. Effective
coverage: pixel `p` is drawn iff `x_left < p + 9/16 <= x_right` in s16.16.)

X clipping (clip_left inclusive, clip_right exclusive):

```
if step > 0:
    if first < clip_left:    first = clip_left
    if last  >= clip_right:  last  = clip_right - 1
    if last < first: next row                       # empty span
else:
    if first >= clip_right:  first = clip_right - 1
    if last  < clip_left:    last  = clip_left
    if last > first: next row                       # empty span
```

Then emit pixels `x = first, first+step, ..., last` INCLUSIVE, each with
parameter values `P(x, y)` per §3 and screen coordinates `(x, y)` (the
y-origin flip is applied downstream by the pixel pipe, see §5). Emission
order is `first → last`; final framebuffer state must not depend on order
within a span (each pixel is touched once).

## 5. Downstream (pixel pipe) coordinate handling

For each emitted pixel `(x, y)`:

```
sy  = fbzMode.bit17 ? (yorigin_eff - y) : y      # yorigin_eff per CONTRACTS §9.5
idx = sy * rowpixels + x                          # 16-bit-word index in buffer
```

Pixels whose color or depth WORD ADDRESS (buffer base + idx) falls outside
the 4 MB framebuffer are dropped (gold) / address-masked (RTL) — traces never
depend on this (CONTRACTS §9.6). Y clipping (§2) happens in PRE-flip space
(86Box convention; MAME clips post-flip — we follow 86Box).

## 6. Worked test vectors (use in unit tests)

Triangle: A=(160,16) B=(32,144) C=(288,144) (12.4 raw; i.e. (10.0,1.0),
(2.0,9.0), (18.0,9.0)). area = (Bx−Ax)(Cy−Ay) − (Cx−Ax)(By−Ay) =
(−128)(128) − (128)(128) = −32768 < 0 → sign = 1 (AC is the right edge).

- dxAC = ((288−160)<<16)/128 = +65536; dxAB = −65536; dxBC ... (By==Cy → 0).
- ystart0 = (16+7)>>4 = 1; yend0 = (144+7)>>4 = 9 → rows 1..8. pA = 10.
- Row y=1: ys=24. xMaj = 655360 + (65536*8)>>4 = 688128 (10.5px);
  xMin = 622592 (9.5px). sign=1: first=(688128−65536+28672)>>16 = 9;
  last=(622592+28672)>>16 = 9. Pixels: {9}.
- Row y=8: ys=136. xMaj = 1146880 (17.5px), xMin = 163840 (2.5px).
  first=(1146880−65536+28672)>>16 = 16; last=(163840+28672)>>16 = 2.
  Pixels: 16,15,...,2 (15 pixels).
- Iterators at (9,1) with startR=0x100000 (12.12), dRdX=0x1000, dRdY=0:
  R = 0x100000 + (9−10)*0x1000 + 0 = 0xFF000 → >>12 = 0xFF.

Tie cases: Ay=24 (1.5px) → ystart0=1: row 1 (center 1.5) IS drawn (top tie
in). Cy=136 (8.5px) → yend0=8: row 8 (center 8.5) NOT drawn (bottom tie out).

## 7. Float register path

Vertices/parameters written through the float registers (0x22–0x3f →
ftriangleCMD) are converted by `float_to_int32/float_to_int64` (MAME
mame_voodoo.cpp:138, already in voodoo_soft.c) into exactly the fixed-point
formats above, then everything proceeds identically. `ftriangleCMD` data
bit 31 is the sign, same as triangleCMD.

## 8. Trace-generator (driver) contract

tracegen acts as a well-behaved driver: sort the three vertices ascending by
y (stable on ties), compute `area = (Bx−Ax)*(Cy−Ay) − (Cx−Ax)*(By−Ay)` in
64-bit on the 12.4 ints, and write triangleCMD/ftriangleCMD data with
bit31 = (area < 0). Fuzz traces may violate this; both models must still
agree (the algorithm is total).
