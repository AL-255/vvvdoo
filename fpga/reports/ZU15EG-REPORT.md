# vvvdoo on Zynq UltraScale+ ZU15EG — timing & area

Out-of-context synthesis + place + route of the **integer backend** (`VOODOO_INT`)
of `voodoo_top`, the synthesizable datapath of the 3Dfx Voodoo Graphics SST-1
reimplementation.

| | |
|---|---|
| **Part** | `xczu15eg-ffvb1156-2-i` (speed grade −2) |
| **Tool** | Vivado 2025.2, OOC flow (synth → opt → place → phys_opt → route) |
| **RTL config** | integer backend (`+define+VOODOO_INT`); `make test` stays pixel-exact |
| **Flow script** | [`fpga/syn/synth_zu15eg.tcl`](../syn/synth_zu15eg.tcl) |
| **Reproduce** | `make fpga` (or `vivado -mode batch -source fpga/syn/synth_zu15eg.tcl -tclargs 4.0`) |

## Memory note (why BRAM/URAM = 0)

On the real SST-1 the **framebuffer (2M×16 = 4 MB)** and **texture store
(1M×16 = 2 MB)** are *external* EDO DRAM, not on-chip. On a ZU15EG board they map
to the on-board **DDR4** behind a memory controller. So they are not synthesized
into fabric — `fb_ram`/`tex_ram` are replaced by single registered read
boundaries ([`fpga/syn/ram_blackbox.sv`](../syn/ram_blackbox.sv), every
address/we/data input kept live) that model the 1-cycle read-return register a
BRAM/URAM/DDR4 port presents. The numbers below are therefore the **fabric
datapath** (rasterizer, TMU, pixel pipeline, command path, arbiters).

> If forced entirely on-chip instead, the 48 Mib of FB+texture would need
> ~113 URAM (only 112 exist) plus BRAM — i.e. it would not fit and is the wrong
> architecture. External DDR4 is correct.

## Area (post-route utilization)

| Resource | Used | Available | % |
|---|---:|---:|---:|
| CLB LUTs (as logic) | **39,626** | 341,280 | 11.6 % |
| LUT as memory | 0 | 184,320 | 0 % |
| CLB Registers (FF) | **19,690** | 682,560 | 2.9 % |
| CARRY8 | **3,690** | 42,660 | 8.7 % |
| F7/F8 muxes | 1,233 / 553 | — | <1 % |
| DSP48E2 | **149** | 3,528 | 4.2 % |
| Block RAM | 0 | 744 | 0 % |
| URAM | 0 | 112 | 0 % |

The design is **small** for this device — it fits comfortably (~12 % LUTs).
The CARRY8 count is dominated by the combinational dividers (below).

## Timing

Constrained at a deliberately aggressive **4.0 ns (250 MHz)** target to expose the
true critical path. Fmax = 1000 / (period − WNS).

| Stage | WNS | Fmax | Critical path |
|---|---:|---:|---|
| **v1: combinational divide** | −66.8 ns | **≈ 14.1 MHz** | combinational integer **divide** |
| Divides pipelined (cut estimate) | −13.5 ns | ≈ 57 MHz | TMU LOD-base DSP multiply chain |
| **v2: SRT divider (shipped)** | −7.70 ns | **≈ 85.5 MHz** | TMU **LOD-base** DSP chain (divide gone) |

**v2** replaces the two combinational divides with a radix-4 **SRT divider**
(`rtl/srt_div.sv`, ported from ventium's Pentium quotient-selection PLA;
bit-identical to `/`, verified over 200k vectors and confirmed byte-identical
GLQuake/m2–m5 frames). Result: **14.1 → 85.5 MHz (6.1×)**; LUTs 39.6k→33.0k,
CARRY8 3690→1531; DSP 149→229 (the divider's residual-correction multiplies).
The critical path has **moved off the divider** onto the TMU LOD-base chain.

### v1 critical path — the perspective/edge divide (now fixed)

Originally two equivalent ~70 ns paths, each ~630–640 logic levels / ~570 CARRY8:
`u_tmu/w0_q → coord_t_q` (perspective `(iters<<8)/iterw`) and
`u_raster … vd_edge_x` (edge/slope `dx·2^20/dy`), both as one combinational
divider. **Replaced by `srt_div`** (radix-4 SRT, multi-cycle): the TMU launches
two instances in `S_DIV` and waits in `S_DIVW`; the raster launches three in
`R_SLOPEW`. The SRT result is bit-identical to `/`, so pixels are unchanged.

### v2 critical path — TMU LOD base (current bottleneck)

With the divides gone, the worst path is now
`u_tmu/value3 (DSP multiply) → lodbase_q` at 11.65 ns (the log2/LOD-base math
from US5831624A) — the tier-2 path the v1 cut-estimate predicted. Registering the
DSP cascade (DSP48E2 has built-in pipeline regs) is the next step past ~85 MHz.

## Takeaways

1. **The integer backend is synthesizable and area-cheap** on the ZU15EG (~12 %
   LUTs, 149 DSP, no fabric RAM). Plenty of headroom for replication/pipelining.
2. **Throughput, not capacity, is the work left.** As written the datapath is
   fully combinational through the divides → 14 MHz. Pipelining the two divides
   reaches ~57 MHz; then pipelining the LOD DSP cascade clears the way to the
   150–250 MHz the rest of the datapath supports on a −2 part. This is M7.
3. **Framebuffer/texture belong in DDR4**, as on the original card; a real
   bring-up adds a DDR4 MIG + read/write FIFOs at the `fb_ram`/`tex_ram` ports.

Raw reports: `post_route_util.rpt`, `post_route_timing.rpt`,
`post_route_worst_paths.rpt`, `ceiling_timing.rpt`, `SUMMARY.txt`.
