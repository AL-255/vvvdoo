# vvvdoo

A **3Dfx Voodoo Graphics (SST-1 / "Voodoo 1")** GPU reimplemented in synthesizable
SystemVerilog — verified **pixel-exact** against a software golden model with
Verilator, and demonstrated **accelerating real GLQuake** in RTL-C co-simulation.

![GLQuake built-in demo (The Necropolis) rendered by the Voodoo RTL](media/glquake-necropolis-rtl.gif)

*GLQuake's built-in attract demo (The Necropolis, e1m3) rendered through the
Verilated Voodoo RTL. Full clip: [`media/glquake-necropolis-rtl.mp4`](media/glquake-necropolis-rtl.mp4).
The frames above were produced by replaying GLQuake's captured Glide command
stream through the RTL — no software rasterizer in the pixel path.*

---

## Status

| Milestone | Scope | State |
|---|---|---|
| **M0** | Foundations: golden model, package, lint, trace harness | ✅ |
| **M1** | Memory, fastfill, LFB, scanout | ✅ pixel-exact |
| **M2** | Triangles: setup, raster, depth, Gouraud | ✅ pixel-exact |
| **M3** | TMU: textures (perspective, LOD/mip, point/bilinear, all formats) | ✅ pixel-exact |
| **M4** | Full pixel pipeline: fog, chroma-key, stipple, alpha/depth, blend | ✅ pixel-exact |
| **M5** | QEMU RTL-C co-simulation (system test) | ✅ runs GLQuake |
| **M6** | FPGA bring-up | ⏳ board TBD |
| **M7** | Pipelining / fill-rate (post-GLQuake) | ⏳ |

`make test` is the gate — it is currently **all PIXEL-EXACT** (RTL frame CRC ==
golden-model frame CRC, byte for byte):

| trace | content | `fb_crc32` |
|---|---|---|
| m1 | fastfill + LFB | `5e7440cc` |
| m2 | Gouraud triangles | `ab2030aa` |
| m3 | textured + perspective selftest | `aea5e256` |
| m4 | full pixel pipeline | `f33891fc` |
| m5 | per-format perspective-textured walls | `d03c5625` |

Beyond the synthetic suite, the **real GLQuake command stream replays through the
RTL byte-identically to the golden model**, and both match a MAME-faithful
reference (see [`docs/MAME-VERIFICATION.md`](docs/MAME-VERIFICATION.md)).

## How it works

The project is built around an **executable specification**:

- **Golden model** (`model/voodoo_gold.c`) — a cycle-agnostic C model of the SST-1
  pixel pipeline that is the reference for *every* pixel. It mirrors MAME's
  `poly.h` float rasterizer (winding-agnostic, round-to-nearest, exclusive spans),
  MAME's `double` perspective/LOD math, and an integer pixel pipeline.
- **RTL** (`rtl/*.sv`) — synthesizable SystemVerilog that mirrors the golden model
  bit-for-bit. `voodoo_top` is the device boundary (host MMIO + LFB + texture
  upload in, framebuffer scanout out).
- **Verilator trace-diff** (`tb/frame/tb_main.cpp`) — replays a `.vvt` command
  trace through both the RTL and the golden model and asserts the framebuffers are
  identical (CRC + per-pixel).
- **`.vvt` traces** — a compact record of the Glide/SST-1 register & memory command
  stream. Synthetic traces come from `tools/tracegen.c`; real ones are captured
  from GLQuake running on the QEMU Voodoo device.

This makes correctness objective: a change is correct iff `make test` stays
pixel-exact, and new behavior must land in the gold model, the RTL, and a trace
together.

### Precision policy

The raster/TMU **front-end** (edge coverage, perspective divide, LOD) runs in
floating point to match MAME exactly. Verilator's `real` is C `double`, so the
gold model also uses `double` for a consistent, testable `gold == RTL`. That
front-end is therefore **simulation-only** (not FPGA-synthesizable as written);
the **pixel pipeline is integer and synthesizable**. Converting the front-end to
fixed-point / soft-float for FPGA is M6/M7 work. Details:
[`docs/raster-algorithm.md`](docs/raster-algorithm.md),
[`docs/MAME-VERIFICATION.md`](docs/MAME-VERIFICATION.md).

## Build & test

Requires `verilator`, a C/C++ toolchain, and `make`.

```sh
make test        # build gold + RTL, run unit tests + m1..m5 trace-diffs (the gate)
make lint        # Verilator lint (-Wall) on the RTL
make sim         # build the Verilated trace-diff testbench (build/vsim)
make cosim       # build the standalone RTL-C co-sim replayer (build/cosim_replay)
make cosim-run   # replay the m3 selftest through the RTL, dump frames + metrics
make clean
```

## RTL-C co-simulation

Two paths drive the *same* Verilated core (`docs/COSIM.md`):

1. **Standalone replay** — `build/cosim_replay <trace.vvt> <out_prefix>` replays a
   captured command stream through the RTL, dumps a PPM per swapped frame, and
   prints acceleration metrics (cycles/frame, fill rate). This is how the GLQuake
   footage above was rendered.
2. **Live QEMU backend** — `make cosim-lib` builds `libvoodoortl.a`, a
   `VoodooRendererOps` implementation over the Verilated model that the QEMU Voodoo
   device (in `vvvdoo-refs/06-qemu-voodoo`) links against (`VOODOO_BACKEND=rtl`), so
   the guest's frames are produced by the RTL.

The GLQuake demo above: GLQuake was launched in QEMU (soft renderer + the device's
`.vvt` recorder), the built-in attract demo was captured (450 swaps, ~18.8M command
records), then replayed through the RTL. The unpipelined core renders it correctly
end-to-end; throughput is functional-model scale (cycle-accurate, not yet
pipelined) — fill-rate work is M7.

## Repository layout

```
model/        voodoo_gold.c/.h    — golden model (executable spec)
rtl/          *.sv                — synthesizable RTL (voodoo_top = device boundary)
tb/
  frame/      tb_main.cpp         — Verilator trace-diff testbench (gold vs RTL)
  unit/       *.cpp               — unit tests (LFB, raster, trace)
  traces/                         — .vvt command traces + golden frames
cosim/
  cosim_replay.cpp                — standalone RTL replay -> frames + metrics
  voodoo_rtl.cpp                  — live QEMU backend (VoodooRendererOps over RTL)
tools/        tracegen.c, vgold_replay.c
docs/         CONTRACTS.md, raster-algorithm.md, MAME-VERIFICATION.md, COSIM.md
fpga/                             — FPGA shim (M6, WIP)
media/                            — demo footage
vvvdoo-refs/                      — submodule: QEMU Voodoo device + reference material
PLAN.md                           — full implementation plan & milestones
```

## Documentation

- [`PLAN.md`](PLAN.md) — architecture, phases, milestones, risks.
- [`docs/CONTRACTS.md`](docs/CONTRACTS.md) — the precise gold/RTL/trace contracts (law for all changes).
- [`docs/raster-algorithm.md`](docs/raster-algorithm.md) — rasterization rule (MAME winding-agnostic) and worked vectors.
- [`docs/MAME-VERIFICATION.md`](docs/MAME-VERIFICATION.md) — bit-exactness verification vs real MAME.
- [`docs/COSIM.md`](docs/COSIM.md) — RTL-C co-simulation guide (both paths, metrics, recorder).

## License & references

See [`LICENSE`](LICENSE). The `vvvdoo-refs` submodule holds the QEMU device and
reference material (some copyrighted); the SST-1 hardware behavior is modeled from
public documentation and the 86Box/MAME open-source implementations.
