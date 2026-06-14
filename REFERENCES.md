# References

Every source consulted while building **vvvdoo** (a 3Dfx Voodoo Graphics / SST-1
GPU in synthesizable SystemVerilog), and how each was used. Most are archived
locally in the `vvvdoo-refs` submodule; external sources are linked.

The project's correctness lineage moved over time: the golden model
(`model/voodoo_gold.c`) was first derived from / verified against **MAME**'s
Voodoo model, then the synthesizable **integer backend** (`make INT=1`) was
re-derived from the **original 3dfx specifications and patents** (with SpinalVoodoo
as a cross-check), so the RTL no longer depends on an emulator as its spec.

---

## 1. Primary hardware specifications — `vvvdoo-refs/01-specs-regs/`

| Document | Role |
|---|---|
| **`Voodoo1_SST-1_Spec_r1.61_199912.pdf`** | **The primary reference.** SST-1 register map, triangle/iterator fixed-point formats (vertices S11.4; RGBA 12.12, Z 20.12, S/T 14.18, 1/W 2.30), rasterization, TMU, and pixel pipeline. The integer backend's arithmetic is derived from this. |
| `FalconFly_3dfx_Technical_Reference.html` | Community-compiled register/behavior cross-reference for the SST-1. |
| `Voodoo2_Spec_r1.16_199912.pdf`, `Voodoo_Rush_SST-96_Spec_r2.2_199911.pdf` | Sibling-chip specs — disambiguated SST-1 behavior and register semantics. |
| `Banshee_Spec_r1.1_199811.pdf`, `Banshee_2D_Databook_r1.0_199806.pdf`, `Voodoo3_Avenger_Spec.pdf`, `Voodoo3_Data_Book_r1.0_199908.pdf` | Later-generation specs, consulted for context and continuity of the pixel pipeline. |

## 2. 3dfx patents — `vvvdoo-refs/05-patents/`

The authoritative description of the hardware algorithms; the integer backend's
LOD, texture-combine, and fog math follow these.

| Patent | Subject | Used for |
|---|---|---|
| **`US5831624A`** | LOD / texture filtering | TMU level-of-detail computation, mipmap/bilinear blend |
| `US5740343A`, `US5870102A` | Texture compositing (+ continuation) | Texture combine unit (`tex_combine`) |
| `US5724561A` | Fog blending | Fog unit |
| `US6088701A` | Command/data transport | Command FIFO / register transport model |

## 3. Glide API documentation — `vvvdoo-refs/02-glide-driver/`

How the driver programs the chip — the contract the RTL's register front-end honors.

- **`Glide_Programming_Guide_3.0_199806.pdf`** / `Glide_Programming_Guide_2.4_199707.pdf` — triangle setup, gradient/parameter formats, texture and fog semantics.
- `Glide_Reference_Manual_3.0_199806.pdf` / `Glide_2.2_Reference_Manual.html` — per-function API reference.
- `Linux_3Dfx_HOWTO.pdf`, `Linux_3Dfx_Archive.html` — driver/setup background.

## 4. Reference implementations (emulators & models) — `vvvdoo-refs/03-emulators/`

- **MAME Voodoo model** (`mame_voodoo.cpp/.h`, `mame_voodoo_render.cpp/.h`, `mame_voodoo_regs.h`, `mame_voodoo_2.*`, `mame_voodoo_banshee.*`, `mame_voodoo_pci.*`) — from [mamedev/mame](https://github.com/mamedev/mame) (GPL-2.0+). The golden model was originally derived from and bit-verified against MAME's `poly.h` rasterizer and `voodoo_render` pixel pipeline. See `docs/MAME-VERIFICATION.md`. *(Now superseded as the RTL's spec by the patents — see intro.)*
- **`3dfx-Glide-API/`** — the open-sourced 3Dfx Glide SDK (init sequences, register definitions, `sst1` headers).
- **`86box_video/`**, `86Box_Display_Settings.html` — 86Box's Voodoo emulation; consulted for an earlier rasterization-rule approach.
- `DOSBox-X_3dfx_Voodoo_Setup_Guide.html` — Voodoo-in-emulator setup background.

## 5. Open RTL implementation (cross-reference) — `vvvdoo-refs/07-rtl-impl/`

- **[SpinalVoodoo](https://github.com/fayalalebrun/SpinalVoodoo)** (`SpinalVoodoo/`) — a working SpinalHDL→Verilog SST-1 implementation (runs on a DE10-Nano). Used to cross-validate the integer backend's fixed-point choices: it independently uses the same formats (RGBA 12.12, Z 20.12, S/T 14.18, 1/W 2.30) and center-sampled (round-nearest) coverage, which confirmed those decisions in `docs/INT-BACKEND-{SPEC,PLAN}.md`.

## 6. QEMU Voodoo device — `vvvdoo-refs/06-qemu-voodoo/`

- A QEMU device model (`src/voodoo.c`) with a soft renderer + a `.vvt` command-stream **recorder** and a pluggable RTL backend. Used to capture real Glide command streams (e.g. GLQuake) for trace-replay verification and the RTL-C co-simulation. `docs/voodoo-mame-spec.md` documents the device's register behavior.

## 7. Industry / architecture analysis — `vvvdoo-refs/04-papers-whitepapers/`

- Microprocessor Report articles (`MPR_*_199603..199808.pdf`) — period analysis of 3D accelerators; architectural/competitive context.

## 8. Index

- `vvvdoo-refs/00-index/INDEX.md` — the reference collection's own index.

---

## 9. Tools used in construction & verification

| Tool | Version | Use |
|---|---|---|
| **Verilator** | 5.047 | RTL lint + cycle-accurate simulation (trace-diff testbench, RTL-C co-sim) |
| **GCC** | 13.3.0 | Golden model (`voodoo_gold.c`), trace tools, `tools/ppm_rmse.c` |
| **QEMU** | (modified, in `vvvdoo-refs/06-qemu-voodoo`) | Real command-stream capture + live RTL co-sim backend |
| **ffmpeg** | 6.1.1 | GLQuake footage assembly; PPM↔PNG; framerate measurement |
| **ImageMagick** | — | Frame montages / visual diffs |
| **socat** | — | Driving the QEMU monitor (headless keystroke/screendump) |

## 10. Test workload / guest

- **GLQuake** + the **Quake** shareware demos (id Software) and the **3Dfx MiniGL** driver, run under **Windows 95** in QEMU — the real program used to generate command streams and validate the RTL on actual gameplay (see `media/` and `docs/COSIM.md`).

---

## Provenance & licensing

The 3dfx specifications, patents, Glide documentation, and Microprocessor Report
articles are archived for reference and remain the property of their respective
authors/owners (3Dfx Interactive / its successors, the USPTO public record, MDR).
MAME source is GPL-2.0+ and was used only as an executable specification to
verify against — the vvvdoo golden model and RTL are an independent
implementation. The Glide SDK and SpinalVoodoo carry their own upstream licenses
(see their directories). This repository's own code is under [`LICENSE`](LICENSE).
