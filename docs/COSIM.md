# RTL-C co-simulation

The Verilated `voodoo_top` RTL (the synthesizable SST-1 hardware model) renders
real 3Dfx Glide command streams under co-simulation with C. Two paths share the
same chip-pin boundary and the same scanout-from-`fb_ram` readback.

## What works (M0–M5)

The RTL is feature-complete for the SST-1 pixel pipeline and matches the golden
model bit-for-bit on every trace (`make test`):

| trace | features | fb crc32 |
|---|---|---|
| m1_fill_lfb   | fastfill, LFB writes/reads (all formats/lanes/swaps), texture DL, DAC, swap | `5e7440cc` |
| m2_tri_gouraud| triangles (fixed+float), depth (Z+W), Gouraud, alpha test/blend, dither | `71100aec` |
| m3_selftest_full | + TMU: textures, LOD, point/bilinear, perspective | `d864b68c` |
| m4_pipeline   | + stipple, chroma key, alpha mask, fog (table+constant), LFB pixel-pipe | `78315ae3` |

## Path 1 — standalone trace replay (`cosim/cosim_replay.cpp`)

Replays a captured `.vvt` command stream through the Verilated RTL, scans out
each frame from the RTL framebuffer, and reports acceleration metrics.

```
make cosim          # build build/cosim_replay
make cosim-run      # replay m3_selftest_full through the RTL -> build/cosim_m3_*.ppm
```

The rendered frame is **byte-identical** to the golden model. Reported metrics
for the selftest frame: ~3.7M cycles, ≈74 ms/frame and ≈4.2 Mpix/s at the
50 MHz SST-1 target clock (correctness-first, unpipelined; one pixel in flight).

## Path 2 — live QEMU (`cosim/voodoo_rtl.cpp`)

The QEMU Voodoo PCI device drives the Verilated RTL through `VoodooRendererOps`
instead of the software renderer. `reg_write` reconstructs a neutral raw BAR
address the RTL re-decodes; LFB/texture forward to `0x400000`/`0x800000`;
scanout reads `fb_ram` via the `scan_*` descriptor ports.

```
make cosim-lib                                   # build/libvoodoortl.a (RTL + bridge)
cp build/libvoodoortl.a            vvvdoo-refs/06-qemu-voodoo/build/qemu/hw/display/
cp vvvdoo-refs/06-qemu-voodoo/src/{voodoo.c,voodoo_soft.c} \
                                   vvvdoo-refs/06-qemu-voodoo/build/qemu/hw/display/
( cd vvvdoo-refs/06-qemu-voodoo/build/qemu/build && ninja qemu-system-i386 )
WAIT_S=16 bash vvvdoo-refs/06-qemu-voodoo/scripts/selftest-rtl-shot.sh   # RTL render
bash       vvvdoo-refs/06-qemu-voodoo/scripts/selftest-shot.sh           # soft (default)
```

`VOODOO_BACKEND=rtl` selects the RTL backend (soft is default). The device's
built-in selftest renders THROUGH the RTL: the full scene (Gouraud + depth +
textured quad + perspective floor) at ~2.62M cycles/frame (≈52 ms @ 50 MHz).
The RTL output matches the golden scene; it differs from the *soft* renderer
only at triangle edges / dithering (the soft renderer uses a float
bounding-box rasterizer, the RTL the hardware-faithful 86Box integer rule).

## Capturing a real guest command stream (`.vvt` recorder)

The QEMU device records every raw BAR access when `VOODOO_VVT=<path>` is set
(`VOODOO_VVT_MAX=N` bounds it to N frames; flushed on clean exit). The result
replays through Path 1.

```
VOODOO_VVT=/tmp/app.vvt VOODOO_VVT_MAX=3 <qemu ... -device voodoo ...>
build/cosim_replay /tmp/app.vvt build/cosim_app
```

## Known limitation / next steps

- **GLQuake capture is blocked on guest bring-up, not the RTL.** GLQuake does
  not currently drive the Voodoo in the Win95 image (the Voodoo console stays
  blank — the 3Dfx MiniGL/Glide/`fxmemmap.vxd` stack needs to be installed and
  launched so `glide2x` maps the BAR). Once a guest issues Voodoo MMIO, the
  recorder captures it and Path 1 replays it on the RTL unchanged.
- **Throughput** is correctness-first (one pixel in flight, per-pixel sequential
  divide in the TMU). Pipelining toward 1 px/clk (~50 Mpix/s) is future work.
- **M6 FPGA**: the core is board-agnostic (generic SRAM ports, no vendor
  primitives); board bring-up is the next milestone (board TBD).
