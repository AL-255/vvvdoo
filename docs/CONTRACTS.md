# vvvdoo implementation contracts

This file pins every cross-module interface for the M0–M2 implementation. All
code (golden model, RTL, testbenches) must follow it **verbatim** — signal
names, bit widths, struct layouts, file paths. If you believe a contract is
wrong, leave the code matching the contract and flag the issue in your report;
do not silently deviate.

Normative behavioral references (in priority order):
1. `vvvdoo-refs/06-qemu-voodoo/docs/voodoo-mame-spec.md` — register map,
   formats, pipeline semantics. THE behavioral spec.
2. `docs/raster-algorithm.md` — the integer rasterization rule (this repo).
3. `vvvdoo-refs/06-qemu-voodoo/src/voodoo_soft.c` — proven (GLQuake-tested)
   reference implementation to port from; deviations from it are listed in §9.
4. MAME / 86Box sources under `vvvdoo-refs/03-emulators/` for tie-breaks.

Target configuration: SST-1, one FBI + one TMU0, **4 MB framebuffer RAM,
2 MB texture RAM**, 16 MB BAR (regs 0x000000, LFB 0x400000, tex 0x800000).

---

## 1. Trace file format (`.vvt`)

Binary, little-endian. The universal test input: a log of raw BAR accesses.

```
Header (8 bytes):  char magic[4] = "VVT1";  uint32_t record_count;
Then record_count records of 16 bytes each:

typedef struct {
    uint8_t  op;        /* see below */
    uint8_t  flags;     /* bit0: for reads, compare returned data against .data */
    uint16_t _rsvd;     /* 0 */
    uint32_t addr;      /* byte offset within the 16MB BAR, dword aligned */
    uint32_t data;      /* write data / expected read data / initEnable value */
    uint32_t mask;      /* 32-bit byte-lane mem_mask (0xffffffff = full dword) */
} vvt_rec_t;

op: 0 = BAR write   (addr/data/mask)
    1 = BAR read    (addr; if flags&1, compare result == data)
    2 = INIT_ENABLE (data = new initEnable value; addr/mask = 0)
    3 = MARK        (frame/section marker, data = user tag; no device effect)
```

All BAR accesses are full 32-bit dwords (QEMU presents min_access_size=4).
The region is implied by addr[23:22]: 00=registers, 01=LFB, 1x=texture.

## 2. BAR register-window decode (normative, from voodoo.c + MAME)

Given a register-window access at byte addr (dword offset `dwoff = addr>>2`):
- `regnum   = dwoff & 0xff`
- `chipmask = (dwoff >> 8) & 0xf`; if 0 → 0xf. (Single-TMU config: consumers
  IGNORE chipmask entirely; keep the decode for tracing/debug.)
- **swizzle**: if `(dwoff & (1<<18)) && fbiInit0 bit3` → byte-swap the 32-bit
  write data.
- **alias**: if `(dwoff & (1<<19)) && fbiInit3 bit0 && regnum < 0x40` →
  `regnum = alias_map[dwoff & 0x3f]` (table in voodoo.c:73, copy it verbatim).
  Applies to reads as well (no swizzle on reads).
- LFB window: `lfb_dwoff = (addr - 0x400000) >> 2`. Texture window:
  `tex_dwoff = (addr - 0x800000) >> 2`. Texture region is write-only
  (reads return 0xffffffff).

## 3. Golden model — `model/voodoo_gold.h` (verbatim API)

C11, zero external dependencies beyond libc/libm. Files: `model/voodoo_gold.h`,
`model/voodoo_gold.c` (+ optional `model/voodoo_gold_priv.h`). Must compile
with `-Wall -Wextra -Werror -O2` cleanly as C and link from C++.

```c
#ifndef VOODOO_GOLD_H
#define VOODOO_GOLD_H
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

#define VGOLD_FB_BYTES   (4u << 20)
#define VGOLD_TEX_BYTES  (2u << 20)

typedef struct vgold vgold_t;

vgold_t  *vgold_create(void);                 /* defaults as in voodoo.c realize:
                                                 640x480, rowpixels 640,
                                                 rgboffs {0,1MB,~0}, aux 2MB,
                                                 frontbuf 0, backbuf 1 */
void      vgold_destroy(vgold_t *g);

/* Raw BAR access; addr = byte offset in the 16MB BAR (dword aligned). */
void      vgold_bar_write(vgold_t *g, uint32_t addr, uint32_t data, uint32_t mask);
uint32_t  vgold_bar_read (vgold_t *g, uint32_t addr);
void      vgold_set_init_enable(vgold_t *g, uint32_t val);

/* State inspection (for the TB differ) */
const uint16_t *vgold_fb(const vgold_t *g);        /* 2M 16-bit words */
const uint8_t  *vgold_texram(const vgold_t *g);    /* 2MB */
int       vgold_frontbuf(const vgold_t *g);
void      vgold_layout(const vgold_t *g, uint32_t rgboffs[3], uint32_t *auxoffs,
                       uint32_t *rowpixels, int *w, int *h);

/* Replay a .vvt trace file. Returns 0 on success, -1 on file/format error,
 * >0 = number of read-compare mismatches (logged to stderr). */
int       vgold_run_trace(vgold_t *g, const char *path);

/* Dump front buffer (w x h, rowpixels stride) as binary P6 PPM. 0 on success. */
int       vgold_dump_ppm(const vgold_t *g, const char *path);

#ifdef __cplusplus
}
#endif
#endif
```

Behavior: port from `voodoo_soft.c` restructured per voodoo-mame-spec.md, with
the rasterizer replaced by the **integer rule of docs/raster-algorithm.md** and
the deviations of §9 applied. The TMU texture path may keep `double` math for
now (M3 will integerize it); everything in the M1/M2 feature set must be pure
integer.

## 4. Trace tools — `tools/`

- `tools/tracegen.c` → `build/tracegen`: writes the milestone traces into
  `tb/traces/` by driving a vgold instance through a recording wrapper (every
  generated access goes both to a vgold and into the .vvt). Traces to emit:
  - `m1_fill_lfb.vvt` — init regs (fbzMode/clip/lfbMode/color1/zaColor),
    several fastfills with/without clip + dither, a few hundred LFB writes in
    formats 0/1/2/4/5 with lane permutes and word/byte swaps, LFB reads,
    swapbufferCMD, MARKs between sections.
  - `m2_tri_gouraud.vvt` — the three Gouraud/depth self-test triangles
    (port the geometry from voodoo_soft_selftest, integer-register path),
    plus: a triangle via the FLOAT register path (fvertex/fstart/ftriangleCMD),
    degenerate triangles (zero area, offscreen, clipped), alpha-test and
    alpha-blend cases, both dither types, rgb/aux mask combinations,
    subpixel-adjust on/off. End with swapbufferCMD.
  - `m3_selftest_full.vvt` — full selftest port including texture download and
    textured/perspective triangles (RTL will use it in M3; gold renders it now).
- `tools/vgold_replay.c` → `build/vgold_replay`:
  `vgold_replay trace.vvt out_fb.bin out.ppm` — replays a trace on gold, writes
  the full 4MB FB to `out_fb.bin`, front buffer to `out.ppm`, prints layout +
  frontbuf + a CRC32 of the FB to stdout.

## 5. RTL — module tree, files, ownership

All RTL is SystemVerilog-2017, synthesizable subset, lint-clean under
`verilator --lint-only -Wall` (waivers only via inline `verilator lint_off`
with justification comment). Style: `always_ff`/`always_comb`, active-low sync
reset `rst_n`, no latches, no `initial` in synthesis paths (memory arrays may
use `initial` zero-fill guarded by `` `ifdef SIMULATION `` only if needed —
prefer explicit reset of control state and uninitialized RAM contents; the TB
zero-fills RAM via the public arrays at t=0).

```
rtl/voodoo_pkg.sv      register indices, field extract functions, tri_params_t
rtl/voodoo_top.sv      top level (ports in §6), instantiates everything
rtl/host_if.sv         host handshake + 64-deep command FIFO + read gating
rtl/reg_decode.sv      BAR reg-window decode (§2): swizzle/alias/chipmask
rtl/voodoo_regfile.sv  256x32 register file + 64-bit S/T/W shadow regs +
                       float->fixed ingest + status read + dacData + derived
                       state (rowpixels, rgboffs, auxoffs, yorigin, w/h)
rtl/cmd_dispatch.sv    pops FIFO; routes reg/lfb/tex; triggers fastfill /
                       triangle / swap; builds tri_params_t (incl. subpixel
                       correction); tracks busy
rtl/float_conv.sv      float_to_int32/64 (combinational, per MAME)
rtl/lfb_unit.sv        LFB write expand (fmts 0,1,2,4,5,12,13,14,15 + lanes +
                       swaps, raw path only for M1) and LFB read
rtl/tex_dl.sv          texture download decode (lod/t/s fields, tLOD swizzles,
                       lodoffset computation) -> tex_ram writes
rtl/fastfill.sv        clip-rect fill of color (dithered color1) + depth
rtl/fb_arb.sv          fixed-priority arbiter onto fb_ram: lfb > fastfill >
                       pixel_pipe (only one active at a time in practice)
rtl/fb_ram.sv          2M x 16 single-port sync RAM, 1-cycle read latency,
                       /* verilator public_flat_rw */ on the array, named `mem`
rtl/tex_ram.sv         1M x 16 RAM, per-byte write enables, public array `mem`
rtl/raster.sv          [raster agent] triangle walker: consumes tri_params_t,
                       emits pixel stream (§7)
rtl/pixel_pipe.sv      [raster agent] per-pixel pipe (M2 scope §8): depth,
                       combine, alpha test/blend, dither, write
```

Dither/compare/alias helpers are pure functions in `voodoo_pkg.sv` (already
written) — use them everywhere (fastfill and pixel_pipe must share them).

Ownership: "core" agent owns everything except the three files marked
[raster agent]. The core agent instantiates raster + pixel_pipe in voodoo_top
using exactly the §7 interfaces (stub behavior until integration: accept and
drop — but wire them, do not `ifdef` them out).

## 6. RTL top-level ports (verbatim)

`voodoo_top` has NO parameters; it imports `voodoo_pkg` (authored by the
integrator at `rtl/voodoo_pkg.sv` — READ-ONLY for all agents; it also contains
the normative `tri_params_t`, register indices, dither/compare/alias helpers).
`FB_AW`/`TEX_AW` are package localparams.

```systemverilog
module voodoo_top
(
    input  logic        clk,
    input  logic        rst_n,

    // Host BAR access (32-bit dword granularity)
    input  logic        host_wr_valid,
    output logic        host_wr_ready,
    input  logic [23:2] host_wr_addr,
    input  logic [31:0] host_wr_data,
    input  logic [3:0]  host_wr_be,      // byte enables (from trace mask)

    input  logic        host_rd_valid,
    output logic        host_rd_ready,
    input  logic [23:2] host_rd_addr,
    output logic        host_rd_resp_valid,  // 1-cycle pulse with data
    output logic [31:0] host_rd_data,

    input  logic [31:0] init_enable,     // PCI config 0x40 (op=2 in traces)

    output logic        busy,            // FIFO non-empty or any engine active
    output logic [1:0]  dbg_frontbuf
);
```

Handshake semantics:
- Writes: accepted (`host_wr_ready`) whenever the command FIFO has space.
- Reads: **status reads (register window, decoded regnum 0) are accepted
  immediately**; ALL other reads (register or LFB) are accepted only when the
  FIFO is empty and no engine is busy (drain-then-read, keeps RTL in-order
  with the gold model). `host_rd_resp_valid` pulses with the data 1+ cycles
  after acceptance. One outstanding read max.
- Register-window decode (swizzle/alias) uses the register state AT EXECUTION
  time (FIFO pop), not enqueue time — a queued fbiInit0/3 write affects the
  decode of subsequent queued accesses, exactly like the in-order gold model.
- The TB must keep driving `clk` while waiting; no combinational paths from
  `*_valid` inputs to `*_ready` outputs are allowed (register the FIFO level).
- `voodoo_top` instantiates `fb_ram` as `u_fb_ram` and `tex_ram` as
  `u_tex_ram` DIRECTLY at top level (TB accesses
  `voodoo_top.u_fb_ram.mem` / `voodoo_top.u_tex_ram.mem`).

Status register (regnum 0) read value (RTL definition — gold differs, traces
never data-check status reads):
- [5:0]  = min(fifo_free_entries/2, 6'h3f)
- [6]    = 1'b1
- [9:7]  = {3{busy}}
- [11:10]= frontbuf index
- [27:12]= 16'hffff
- [31:28]= 0

## 7. RTL internal interfaces (verbatim)

### 7.1 `tri_params_t`

Normative definition lives in `rtl/voodoo_pkg.sv` (read-only for agents).
It includes a `sign` bit = bit 31 of the data written to (f)triangleCMD
(see docs/raster-algorithm.md §1).

`clip_*`: if fbzMode bit0 clear, dispatch supplies {0, width, 0, height}.
Subpixel correction (fbzcp bit26) is applied by **dispatch** before launch to
startr..starta, startz, startw, s0/t0/w0 using the 86Box mod-16 formula of
docs/raster-algorithm.md §2 (NOT MAME's signed form).

### 7.2 Triangle launch / pixel stream

```systemverilog
// dispatch -> raster
output logic        tri_valid;
input  logic        tri_ready;     // raster idle
output tri_params_t tri_params;

// raster -> pixel_pipe (one beat per candidate pixel inside the triangle
// and clip rect; iterator values are RAW accumulations, unclamped)
output logic        px_valid;
input  logic        px_ready;
output logic        px_last;        // last pixel of this triangle
output logic [9:0]  px_x, px_y;     // screen coords pre-yflip
output logic signed [31:0] px_r, px_g, px_b, px_a;   // 12.12
output logic signed [31:0] px_z;                     // 20.12
output logic signed [63:0] px_w;                     // 16.32
output logic signed [63:0] px_s0, px_t0, px_w0;      // M3 (pipe ignores in M2)
// raster also passes through a registered copy of tri_params (or pipe keeps
// its own copy latched at tri_valid&tri_ready — pipe owns the latch).
output logic        tri_done;       // pulses when last pixel retired in pipe
```

Iterator math (normative): per docs/raster-algorithm.md §3 — at each pixel
`(x, y)`: `val = start_adj + (x - pA)*ddx + (y - ystart0)*ddy` with
`pA = (ax + 7) >>> 4`, `ystart0 = (ay + 7) >>> 4` (UNCLIPPED), arithmetic
mod 2^32 (rgba/z) / mod 2^64 (w/s/t). Incremental schemes allowed if
bit-identical.

### 7.3 Framebuffer memory port (fb_arb client port; one per client)

```systemverilog
// request
output logic              req_valid;
input  logic              req_ready;
output logic              req_we;
output logic [FB_AW-1:0]  req_addr;    // 16-bit word address
output logic [15:0]       req_wdata;
// response (reads only, in order, 1+ cycle latency)
input  logic              rsp_valid;
input  logic [15:0]       rsp_rdata;
```

Clients in priority order: 0=lfb_unit, 1=fastfill, 2=pixel_pipe. tex_ram has a
single write client (tex_dl) and no read client yet (M3); port shape is the
same but 32-bit-with-byte-enables:
`req_addr[TEX_AW-1:0]` (16-bit word addr), `req_wdata[15:0]`, `req_be[1:0]`.

## 8. Milestone feature scopes

**M1 (core agent)**: register file + decode + status; fastfillCMD (dithered
color1 fill per fbzMode bit8/bit11 dither type, clip rect, rgb/aux masks);
swapbufferCMD (immediate rotate, §9); nopCMD (accept, no-op); LFB raw writes
(pixel-pipeline LFB path is M4) for formats 0,1,2,4,5,12,13,14,15 with
rgba_lanes, word_swap, byte_swizzle, y-origin flip; LFB reads; texture
download writes (full decode, both bpt). videoDimensions/fbiInit1/2/3 derived
state. dacData state machine (gold parity).

LFB raw-write details (normative, port from MAME internal_lfb_w:1570-1678 +
expand_lfb_data:1719-1872 — voodoo_soft.c is WRONG here):
- `offset <<= 1` ONLY when the expansion yields two pixels (PIXEL1 present);
  one-pixel formats address one pixel per dword.
- Present-mask is ANDed with the mem_mask halves exactly as MAME does:
  low half absent → clear pixel-0 flags EXCEPT depth-MSW; high half absent →
  clear pixel-1 flags AND depth-MSW-0.
- RGB writes are DITHERED through the same dither565 helper as the pixel pipe
  (fbzMode bit8 enable, bit11 type; x = pixel x, y = post-flip scry). Channel
  inputs are the 888 expansions (bit-replication for 5/6-bit sources).
- If fbzMode.enable_alpha_planes (bit18): ALPHA-present writes store the
  pixel's alpha to aux; otherwise DEPTH/DEPTH-MSW-present writes store the
  format's depth (default src_depth = zaColor[15:0], src_alpha = zaColor
  [31:24]).
- fbiPixelsOut increments once per present pixel slot regardless of masks.

**M2 (raster agent)**: triangle walk per docs/raster-algorithm.md; iterators;
depth pipeline: depthval = Z-path (clamped >>12, pseudo-clamp vs saturate per
fbzcp bit28) or wfloat path (fbzMode bit3) + depth bias (bit16, add
sext16(zaColor), clamp [0,0xffff]) + depth_source_compare (bit20 → u16
zaColor); depth test (8 funcs vs aux[idx]); color combine per spec §4 step 7
**without texture** (texel input = {255,255,255,255}, cc_rgbselect=1 selects
that constant; chroma key + alpha mask = M4, but structure the code so they
slot in); alpha test; alpha blend (all factor codes incl. 15; dst_alpha = 255;
A_COLOR references per spec); fog = M4 (skip); dither 4x4 and 2x2; rgb/aux
write masks; fbiPixelsOut counter increment per written pixel.

Pixel discard at any stage consumes the beat without memory writes.

## 9. Intentional deviations from voodoo_soft.c (gold + RTL implement THESE)

1. **Rasterization rule**: integer edge-walk per docs/raster-algorithm.md,
   NOT the float bounding-box/barycentric loop of voodoo_soft.c.
2. **LFB depth writes**: only when the format's present-mask carries depth
   (MAME-correct), not unconditionally.
3. **Fastfill dithers** color1 through the same RGB dither as pixel writes
   (honoring fbzMode dither enable + type), per MAME.
4. swapbufferCMD executes immediately (no vblank wait) — matches voodoo_soft;
   bit0/count semantics deferred until video timing exists.
5. y-origin: effective yorigin = (fbiInit3[31:22] != 0) ? fbiInit3[31:22]
   : (height-1) — matches voodoo_soft's fallback. Same rule in gold + RTL.
6. Out-of-range guard (identical in gold and RTL): for a pixel with computed
   post-flip row `sy` and buffer-relative word index `idx = sy*rowpixels + x`,
   the color (resp. depth) write/read is DROPPED iff `sy < 0` or `sy > 1023`
   or `buffer_base_words + idx >= 2^21` (computed without wrap). Applies to
   the pixel pipe, fastfill and LFB paths alike. Tracegen keeps geometry in
   range anyway.
7. No PCI/memory FIFO timing fidelity; status free-space bits differ between
   gold and RTL (never data-checked in traces).
8. Color combine: implement full spec §4/§226 semantics (voodoo_soft's
   `combine()` lacks cc_mselect=4 texel-alpha path distinctions etc. — follow
   the spec doc; for M2, texel inputs are constant white).
9. The rasterizer ALWAYS clips to an effective rect (= clip regs when fbzMode
   bit0, else {0,width,0,height}); 86Box only clips when enabled. Both gold
   and RTL apply this rule identically.
10. lfbMode bit8 (pixel-pipeline LFB writes) is treated as raw until M4;
   tracegen must not set it.
11. (resolved at integration) fastfill uses the clip-rect REGISTERS
   unconditionally (MAME reg_fastfill_w) — the fbzMode-bit0 gate applies to
   the triangle path only.
12. (resolved at integration) Draw-buffer select for triangle/fastfill/LFB
   WRITES: 0=front, 1=back, 2/3 = the whole operation is DROPPED (MAME
   draw_buffer_indirect null). LFB READS: 0=front, 1=back, 2=aux,
   3 = 0xffffffff.
13. pixel_pipe must pulse tri_done even for zero-pixel triangles —
   cmd_dispatch waits for it unconditionally after every launch.

## 10. Build system

Root `Makefile` (GNU make) targets — keep them working at every commit:
- `make gold`      → `build/libvgold.a`, `build/vgold_replay`, `build/tracegen`
- `make traces`    → runs tracegen, emits `tb/traces/*.vvt` + golden
                     `tb/traces/golden/*.ppm` + `*.fb.crc`
- `make lint`      → `verilator --lint-only -Wall` over `rtl/*.sv` (top:
                     voodoo_top)
- `make sim`       → Verilates `rtl/` with `tb/frame/tb_main.cpp` into
                     `build/vsim` (`--cc --exe --build -O3 -j 0 --assert`;
                     add `--trace-fst` under `WAVES=1`)
- `make test-m1`   → `build/vsim tb/traces/m1_fill_lfb.vvt` (replays on RTL +
                     gold in-process, diffs FB, exit 0 on pixel-exact)
- `make test-m2`   → same with m2 trace
- `make test`      → unit tests + test-m1 + test-m2
- `make unit`      → builds & runs `tb/unit/*` C++ tests (link libvgold).
  This turn the unit tests are GOLD-level (drive vgold via its public API):
  (a) raster rule on the worked vectors of docs/raster-algorithm.md §6 plus
  tie cases, asserting the exact covered-pixel sets; (b) LFB format expansion
  known-vectors; (c) trace round-trip through vgold_run_trace. RTL-block unit
  TBs come later; the frame differ is the RTL workhorse.

C/C++: `-O2 -g -Wall -Wextra -Werror`. C11 for model/tools, C++17 for TB.

## 11. Frame TB (`tb/frame/tb_main.cpp`) behavior

1. Parse args: `vsim <trace.vvt> [--waves out.fst] [--max-cycles N]`.
2. Instantiate gold (`vgold_create`) and Verilated `voodoo_top`; zero both
   memories (RTL via the public `mem` arrays).
3. Stream the trace into BOTH: gold via `vgold_bar_write/read`; RTL via the
   host ports respecting ready/valid (writes use be = nonzero bytes of mask).
   op=2 drives `init_enable` (both). Reads: drive, wait for resp, optional
   compare when flags&1 (status regnum-0 reads are never compared even if the
   flag is set — defensive).
4. After the last record: wait for `!busy` + FIFO drain (bounded by
   --max-cycles, default 200M).
5. Compare: full 4MB fb_ram vs `vgold_fb` (16-bit words), frontbuf index.
   On mismatch: print first 32 mismatches as (word_index, x, y, buffer-region,
   rtl, gold), write `out_rtl.ppm` + `out_gold.ppm` + `out_diff.ppm`
   (diff = red where mismatched), exit 1. On match print `PIXEL-EXACT` +
   CRC32, exit 0.
6. The PPM writer: front buffer, width x height from gold layout, 565→888
   replicate-bits expansion identical to gold's `from565`.

## 11b. M3 — TMU (texture mapping unit)

The golden model `model/voodoo_gold.c` is now FULLY INTEGER in the texture path
(no float/double) and is the FROZEN bit-exact spec. RTL must match it. Key gold
functions to mirror: `tex_recompute`, `compute_lodbase`, `fast_log2_i64`,
`fast_log2_u128`, `fetch_texel`, `texel_expand`, `lookup_texel`,
`combine_generic`, and the per-pixel texturing block in the rasterizer
(`texel = combine_generic(ctex, zero, raw, raw.a, 0)`).

Arithmetic decisions (normative, already in gold):
- Perspective: `s = trunc((S*256)/W)`, `t = trunc((T*256)/W)` via a real
  (128-bit numerator) signed divide truncating toward zero; `W==0`→1.
  `lod -= fast_log2_i64(W, 32)`.
- Affine (no perspective): `s = trunc(S / 2^24)`, `t = trunc(T / 2^24)`.
- `fast_log2_i64(v, f)`: v<0→0; v==0→`(-(1023+f))<<8`; else
  `((p - f) << 8) | table[m7]` where `p = 63 - clz64(v)` and m7 = the 7 bits
  just below the MSB (`(v>>(p-7))&127`, or `(v<<(7-p))&127` for p<7).
- `compute_lodbase`: `fast_log2_u128(max(ds·ds+dt·dt over x, over y), 64) / 2`
  using exact 128-bit sums of the signed 64-bit S/T gradients.
- LOD select: `lod += lodbias; clamp[lodmin,lodmax]; ilod = lod>>8;
  ilod += (~lodmask>>ilod)&1; cap 8`. Filter: point vs bilinear per the gold
  predicate; bilinear keeps 4 fractional bits (`&0xf0`), weights `>>8`.
- `lodoffset[0..8]` chain exactly as gold `tex_recompute` (raw footprint LOD
  1-3, min-4-texel clamp LOD 4-8, `<<bppscale`, `& TEX_MASK`).
- Texel address: bpt1 `(texbase + t + s) & TEX_MASK`; bpt2
  `(texbase + 2*(t+s)) & TEX_MASK & ~1`. `t` is pre-multiplied by `smax+1`.
- Texture-combine is part of the TMU: it returns the POST-`combine_generic`
  texel (control = TM_tc_*/TM_tca_* fields), which pixel_pipe feeds into the
  color-combine `texel` input.

Interfaces (verbatim):
- `tex_ram` GAINS a read port (write port unchanged):
  `input logic [TEX_AW-1:0] addr_r; output logic [15:0] rdata_r;` with 1-cycle
  registered read latency. tex_dl (write) and the TMU (read) are temporally
  disjoint, so no arbitration is required.
- New module `rtl/tmu.sv`. It latches tri_params at `tri_valid&&tri_ready`
  (same launch as pixel_pipe), does per-triangle setup, and serves a per-pixel
  sample request from pixel_pipe:
  ```
  input  logic        smp_valid;   output logic smp_ready;   // request
  input  logic [63:0] smp_s0, smp_t0, smp_w0;
  output logic        tex_valid;   input  logic tex_ready;   // response
  output logic [7:0]  tex_a, tex_r, tex_g, tex_b;            // post-combine
  output logic [TEX_AW-1:0] trd_addr; input logic [15:0] trd_data; // to tex_ram
  ```
  Multi-cycle (sequential divider, sequential 1–4 texel reads) is fine.
- `pixel_pipe`: when `tri_params.fbzcp[27] && tri_params.texmode != 0`
  (texturing), at the color-combine stage it issues `smp_*` with the pixel's
  s0/t0/w0 and stalls until `tex_valid`, using the returned ARGB as the texel
  input; otherwise the texel stays constant white (M2 behavior). The texturing
  predicate and constant-white default must match gold exactly.
- `voodoo_top` instantiates `tmu u_tmu`, wires it between pixel_pipe and
  u_tex_ram's new read port, and routes tri launch to it.

M3 done = `make lint` clean; `make test` (unit + test-m1 + test-m2 + test-m3)
all PIXEL-EXACT. test-m1/m2 must NOT regress.

## 12. Definition of done (this turn)

- `make lint` clean; `make gold traces unit` green.
- `make test-m1` PIXEL-EXACT.
- `make test-m2` PIXEL-EXACT.
- `m3_selftest_full.vvt` renders correctly on gold (PPM visually equals the
  reference selftest screenshot in vvvdoo-refs/06-qemu-voodoo/shots/) — RTL
  parity for it lands with M3 (TMU).
