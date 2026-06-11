# vvvdoo — Voodoo Graphics (SST-1) in SystemVerilog: Implementation Plan

Goal: a synthesizable, register-compatible 3Dfx Voodoo Graphics (SST-1 / Voodoo-1)
core in Verilog/SystemVerilog, verified pixel-exactly against a software golden
model with Verilator, integrated into the existing QEMU machine as a co-simulated
PCI device, and finally deployed to FPGA boards running GLQuake.

## 0. What we already have (vvvdoo-refs)

| Asset | Why it matters |
| --- | --- |
| `06-qemu-voodoo/docs/voodoo-mame-spec.md` | Verified register-level contract (register map, fixed-point formats, pipeline order, LFB/texture decode, video timing). **This is the RTL spec.** |
| `06-qemu-voodoo/src/voodoo_soft.c` (+`voodoo.c`, `voodoo_render.h`) | Working software SST-1 behind a chip-pin-level pluggable boundary (`VoodooRendererOps`). The natural **golden model** and the co-sim socket for the RTL. |
| QEMU machine + Win95 images + GLQuake injection scripts | End-to-end system test: real Glide driver stack exercising the device. |
| Built-in render self-test + golden screenshots (`shots/`) | Deterministic frame-level acceptance test with no guest OS. |
| `01-specs-regs/Voodoo1_SST-1_Spec_r1.61` | Authoritative hardware spec (registers, FIFOs, memory organization, timing). |
| MAME `voodoo*` + 86Box `vid_voodoo*` sources | Two independent behavioral references for resolving ambiguities. |
| Glide 2.x source + manuals | Defines which hardware features the driver actually uses (priority order for RTL features). |
| Patents US5740343A / US5831624A / US5724561A | Hardware-structure hints for TMU combine cascade, LOD filtering, fog blend. |

Target configuration (matches the QEMU device): SST-1, **1 FBI + 1 TMU**, 4 MB
framebuffer RAM, 1 MB texture RAM, 16 MB BAR split 4M regs / 4M LFB / 8M texture.

## 1. Architecture

### 1.1 RTL top-level boundary

Mirror `VoodooRendererOps` exactly — it was designed as the chip-pin surface:

```
voodoo_top
 ├─ host_if        : write port {addr[23:2], data[31:0], be[3:0]} + read port, plus
 │                   backpressure (FIFO-full). Maps 1:1 onto reg/lfb/tex BAR regions.
 ├─ pci_fifo       : command FIFO + status register semantics (free-space counts,
 │                   busy bits, swaps pending) per spec §1/§2.
 ├─ reg_file       : 256 x 32 register file, chipmask decode, swizzle/alias decode.
 ├─ cmd_dispatch   : triangleCMD/ftriangleCMD/nopCMD/fastfillCMD/swapbufferCMD.
 ├─ setup          : float→fixed conversion (ftriangle path), subpixel correction.
 ├─ raster         : edge-walk rasterizer; per-pixel iterators
 │                   (ARGB 12.20, Z 20.12, W 16.48, S/T 14.18-extended), clipping.
 ├─ tmu0           : LOD calc, perspective reciprocal, texel address gen,
 │                   format expansion (RGB332/A8/I8/AI44/NCC/565/1555/4444),
 │                   point/bilinear filter, texture color combine.
 ├─ pixel_pipe     : stipple → wfloat → depth test → color combine (chroma key,
 │                   alpha mask) → alpha test → fog → alpha blend → dither → write.
 │                   Order is normative (spec §4).
 ├─ lfb_unit       : LFB read/write, format expansion, raw vs pixel-pipeline path.
 ├─ fb_memctl      : framebuffer memory controller (RMW for depth/blend),
 │                   buffer layout from fbiInit2, arbitration with scanout.
 ├─ tex_memctl     : texture RAM port (download writes + filtered reads).
 └─ video_out      : timing generator from hSync/vSync/backPorch/videoDimensions,
                     front-buffer scanout, 565→888 CLUT, vblank/vRetrace, swap-on-vblank.
```

Memory is behind generic synchronous SRAM-style ports so simulation uses plain
arrays and each FPGA board supplies its own backend (BRAM / SDRAM / DDR). No
vendor primitives in the core.

### 1.2 Performance target

Real SST-1: 50 MHz, ~1 pixel/clock sustained. Initial RTL: correctness first,
one pixel in flight is acceptable; then pipeline to 1 px/clk. The pixel pipe
needs depth-read + dest-read + conditional writeback per pixel — design
fb_memctl for that RMW pattern from the start (it dominates feasibility).

### 1.3 Precision policy (key early decision)

The golden model must be **bit-exact reproducible in RTL**. MAME (and the
current `voodoo_soft.c`) uses `double` for TMU S/T/W iteration, `256.0/w`
perspective recip, and a double-based `fast_log2`. Real hardware was fixed-point.

**Step one of the RTL effort is to integerize `voodoo_soft.c`**: s64 fixed-point
TMU iterators (matching the FBI ones), a defined fixed-point reciprocal
(e.g. table + Newton-Raphson with specified width), and an integer log2.
Re-validate the integerized model against the existing golden screenshots and
GLQuake visuals, then freeze it as `voodoo_gold`. Every RTL block then has an
exactly matching C function to diff against. Where MAME's float behavior and a
sane fixed-point design disagree, the spec is what the Glide driver tolerates —
verify with the QEMU GLQuake run, and note deviations in the spec doc.

## 2. Repository layout

```
vvvdoo/
├── PLAN.md
├── rtl/                  # synthesizable SV (core only, no vendor code)
├── model/                # voodoo_gold: integerized golden model (C, shared with QEMU)
├── tb/
│   ├── unit/             # per-block Verilator testbenches (diff vs voodoo_gold)
│   ├── frame/            # trace-replay harness: full-chip Verilated model
│   └── traces/           # recorded BAR-access traces (selftest, glide tests, quake)
├── sim/                  # Verilator build (CMake or Make), lint config
├── cosim/                # voodoo_rtl.c QEMU backend wrapping the Verilated core
├── fpga/
│   ├── common/           # board-agnostic shims (memctl backends, video PHY)
│   └── <board>/          # per-board top, constraints, build scripts
└── vvvdoo-refs/          # (existing submodule)
```

## 3. Phases and milestones

Each milestone has a mechanical exit criterion. Pixel-exact = framebuffer
contents identical between Verilated RTL and `voodoo_gold` for the same input
trace.

### M0 — Foundations
- Verilator 5.x + toolchain setup, lint-clean skeleton `voodoo_top` with host_if,
  reg_file, status register readback.
- **Integerize and freeze `voodoo_gold`** (see §1.3); keep QEMU using it so the
  golden model stays continuously system-tested.
- **Trace recorder**: add a record mode to `voodoo.c` that logs every BAR access
  (region, offset, data, mask) to a file. Record: selftest, Glide init sequence,
  GLQuake timedemo segments. Traces are the universal test input.
- Frame-replay harness in `tb/frame/`: feeds a trace to both voodoo_gold and the
  Verilated top, dumps and diffs framebuffers, renders PNGs of mismatches.
- Exit: register write/read trace replays with correct status/register readback.

### M1 — Memory, fastfill, LFB, scanout
- fb_memctl + buffer layout (fbiInit2 pages, front/back/aux), fastfillCMD,
  swapbufferCMD (immediate + vblank-synced), LFB raw writes/reads (all formats,
  swizzles), video timing + scanout + CLUT, vRetrace.
- Exit: a trace doing init + fastfill + LFB writes + swap is pixel-exact;
  scanout testbench produces a correct PPM frame.

### M2 — Triangles: setup, raster, depth, Gouraud
- Fixed and float vertex paths (float→fixed converters), subpixel correction,
  edge-walk rasterizer with clipping, ARGB/Z iterators, depth test (Z and
  wfloat paths, bias, all 8 functions), color path (iterated RGB only),
  dithered 565 write, pixel counters (fbiPixelsIn/Out, fail counters).
- Exit: selftest trace through the Gouraud + depth-test triangles pixel-exact.
  Randomized triangle fuzzing (random state words + random vertices, thousands
  of cases) pixel-exact vs voodoo_gold.

### M3 — TMU: textures
- Texture download decode (TMU/LOD/T/S address fields, swizzles), texBaseAddr /
  tLOD LOD offset computation, point sampling then bilinear, formats in driver
  priority order: 565, 1555, 4444, I8, A8, AI44, RGB332, then NCC/palette.
- Perspective recip + LOD computation per the frozen fixed-point definition;
  texture color combine unit (full mselect/reverse/invert cascade — patent
  US5740343A is the structural reference).
- Exit: selftest textured quad + perspective triangle pixel-exact; texture-format
  sweep fuzzing pixel-exact.

### M4 — Full pixel pipeline
- Chroma key, alpha mask, alpha test, fog (table + iterated/Z/W sources, fog
  deltas), alpha blending (all src/dst factor codes incl. SATURATE /
  COLORBEFOREFOG), stipple, LFB writes through the pixel pipeline,
  color-combine corner modes (cc_mselect texel-alpha, a_local Z/W selects,
  pseudo vs saturate clamp).
- Exit: full register-state fuzzing (constrained-random state words × random
  triangles) pixel-exact; all recorded Glide-demo traces pixel-exact.

### M5 — QEMU co-simulation (system test)
- `cosim/voodoo_rtl.c`: implement `VoodooRendererOps` around the Verilated core
  (link libverilated into the QEMU build; clock the core from a QEMU thread,
  forward BAR accesses, scanout from RTL framebuffer memory).
- FIFO semantics under real driver timing: PCI FIFO depth/watermarks, memory
  FIFO, busy/stall behavior — Glide spins on the status register, so this is
  where FIFO bugs surface.
- Exit: Win95 boots with the RTL device, Glide initializes (DAC/init handshake
  works), **GLQuake runs on the RTL** (slow is fine; use a short timedemo +
  screenshot diff vs the soft renderer's golden shots).

### M6 — FPGA bring-up
- Board port 1 (recommended: a Zynq-7000 class board — e.g. Pynq-Z2/Arty Z7 —
  DDR3 for FB+texture RAM, HDMI out for scanout, ARM PS as the "PC"):
  - fb/tex memctl backends onto the PS DDR (or PL DDR) with a scanout FIFO;
    bandwidth budget: 640×480×16@60 scanout ≈ 37 MB/s + render RMW — comfortably
    within DDR3, but arbitration needs a proper burst design.
  - AXI-Lite/AXI slave shim exposing the 16 MB BAR window to the ARM.
  - Host software on the ARM (Linux): map the window via /dev/mem or UIO, port
    the open Glide 2.x tree (refs has it) to write directly to the mapped BAR,
    run Linux GLQuake/sdlquake-glide.
- Timing closure at 50 MHz core clock first; CDC between core, DDR, and pixel
  clocks via the scanout FIFO and host FIFO.
- Exit: GLQuake timedemo rendering on a monitor from the FPGA.

### M7 — Stretch (post-GLQuake)
- Second board port (pick per available hardware — ECP5/LiteX for open tools, or
  a PCIe Artix board with a PCIe→BAR shim so a PC can drive it like a real card).
- Performance: full 1 px/clk pipelining, then >50 MHz.
- Voodoo-2 features (second TMU, triangle setup engine `sSetupMode`) if desired.

## 4. Verification strategy (summary)

Four reinforcing layers, all anchored on the frozen integer golden model:

1. **Unit diff tests** (`tb/unit/`): each RTL block vs the corresponding
   voodoo_gold function (float→fixed, wfloat/depthval, compare units, color
   combine, fog, blend factors, dither, texel address gen, format expanders,
   bilinear). Exhaustive where the domain is small (compare functions, dither),
   constrained-random elsewhere. Run in CI on every commit.
2. **Frame-level trace replay** (`tb/frame/`): recorded BAR traces replayed into
   gold + RTL, pixel-exact framebuffer diff. Fast, deterministic, debuggable
   (FST waves on mismatch). This is the workhorse.
3. **Constrained-random fuzzing**: random state-register words × random
   geometry, gold vs RTL, with automatic trace minimization on mismatch.
4. **QEMU co-sim**: the real Glide/MiniGL/GLQuake stack against the RTL —
   catches FIFO/timing/init behavior no trace replay will.

## 5. Risks / open questions

- **MAME-vs-hardware fidelity**: our contract is "what the Glide driver needs",
  validated by GLQuake under QEMU — not cycle accuracy. Acceptable for the goal;
  86Box source is the tiebreaker when MAME looks suspicious.
- **Integerization deltas**: replacing doubles may shift LOD/perspective by an
  LSB in corner cases. Mitigation: diff integerized model vs original
  float model over the GLQuake traces; accept only sub-LSB visual deltas.
- **DDR RMW latency** vs the per-pixel depth/blend loop: needs a small write-back
  cache or span-buffered design in fb_memctl on FPGA. Designing the memctl
  interface for burst/span access from M1 avoids a painful retrofit.
- **NCC/palette textures**: GLQuake uses paletted textures via NCC tables — not
  optional, schedule inside M3.
- **Board choice for M6**: plan assumes Zynq-class; confirm actual hardware on
  hand before M6 and adjust the shim layer (the core itself is board-agnostic).
