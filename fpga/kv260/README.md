# vvvdoo on KV260 — board deployment groundwork

Target board: **Xilinx Kria KV260** (Kria K26 SOM, device `xck26-sfvc784-2LV-c`, ZU5EV-class MPSoC). Vivado board part `xilinx.com:k26c:part0:1.4`. Toolchain: Vivado 2025.2 (`/tools/Xilinx/2025.2`).

This document is the implementation plan for getting the Voodoo-1 RTL (`rtl/voodoo_top.sv`) running on the KV260 PL, driven by QEMU-on-PS through an AXI host shim. It supersedes the earlier "both memories on-chip" sketch — that config is **physically impossible on `xck26`** (see Memory Plan) and has been replaced with a DDR4-framebuffer architecture, which the ZU15EG OOC study already identified as the correct one.

---

## 0. Scaffold status (this groundwork pass)

Created and verified in this pass (board RTL is isolated under `fpga/kv260/rtl/`
so it can never disturb the `make test` gate — that flow globs only `rtl/*.sv`):

| File | State |
|---|---|
| `fpga/kv260/rtl/axi_voodoo_slave.sv` | **done** — synthesizable AXI4 slave + AXI4-Lite STAT sideband, all verified protocol fixes; **Verilator-lint-clean** (`make kv260-lint`). |
| `fpga/kv260/rtl/fb_ddr_adapter.sv` | **skeleton** — interface defined, datapath is M7 (needs the `fb_arb` rewrite). |
| `cosim/voodoo_hw.cpp` | **done (skeleton)** — `VOODOO_BACKEND=hw` backend over `/dev/mem`; **compiles** against `voodoo_render.h`. |
| `fpga/kv260/bd_voodoo.tcl` | recipe — full BD + a `FIT_ONLY=1` synth-only fit gate. |
| `fpga/kv260/voodoo_kv260.xdc` | done — timed synchronous reset (no false-path), 50 MHz. |
| `fpga/kv260/voodoo.dts`, `shell.json`, `Makefile.frag` | done — overlay + dfx metadata + `kv260-*` build targets. |

Ground-truth fit (Vivado 2025.2 OOC, `xck26-sfvc784-2LV-c`, integer backend + SRT
divider, RAMs black-boxed): **LUT 28.0% / FF 9.5% / DSP 18.4% / BRAM 0 / URAM 0** —
the datapath fits with large headroom; memory placement (below) is the real work.

Remaining engineering is the numbered checklist in §6 (next: the `fb_arb` rewrite +
`fb_ddr_adapter` datapath, then the Vivado BD).

---

## 1. Architecture overview

The x86 emulator (QEMU `qemu-system-i386`, TCG) runs on the PS Cortex-A53 cluster and presents a PCI Voodoo card to the guest (Win95/GLQuake). Every guest BAR access traps into QEMU's `voodoo.c`, which forwards it through the `VoodooRendererOps` vtable. On the board we plug in a new backend `voodoo_hw_create()` (selected by `VOODOO_BACKEND=hw`) that re-implements the cosim `RtlPriv` primitives (`bar_write`/`bar_read`/`fb`/`drain`) as **AXI MMIO** into the PL plus a framebuffer readback.

The PL holds `voodoo_top` (unmodified host port) behind a new **AXI4 slave wrapper** (`axi_voodoo_slave`). The wrapper bridges:

- a wide **S_AXI_BAR** port (the 16 MB device aperture: regs / LFB / texture) → `voodoo_top`'s `host_wr_*` / `host_rd_*` ports, and
- a small **S_AXI_STAT** AXI4-Lite sideband exposing `busy`, `dbg_frontbuf`, the scanout descriptor, and `init_enable` as plain (never-draining) registers.

The framebuffer (4 MB) lives in **PS DDR4**, reached by `voodoo_top` through a new `fb_ddr_adapter` AXI master into an S_AXI_HP slave port. Texture (reduced) stays on-chip in URAM. The A53 reads the front buffer back from a known DDR address and blits 565→8888 into QEMU's DisplayPort surface.

There is **no guest-visible bus-master DMA** in this device model (verified: no `pci_dma_*`/`dma_memory_*`/`pci_set_master` in `voodoo.c`). All guest traffic is host-initiated single-dword PIO writes. The only DMA-shaped flow is the host driving bulk uploads / reading the framebuffer, both shim-side and optional.

### Block diagram

```
  +-------------------------------- KV260 SOM (xck26-sfvc784-2LV) --------------------------------+
  |                                                                                              |
  |   PS (APU: 4x Cortex-A53)                                  PL (programmable logic)           |
  |  +-------------------------------+                       +-------------------------------+   |
  |  |  Linux (PetaLinux / Ubuntu)   |                       |  axi_voodoo_slave  (ACLK=clk) |   |
  |  |                               |   M_AXI_HPM0_LPD       |  +-------------------------+  |   |
  |  |  QEMU qemu-system-i386 (TCG)  |   @0x8000_0000 (16MB)  |  | S_AXI_BAR (AXI4)        |  |   |
  |  |   guest: Win95 + GLQuake      |======================>|  |  AW/W/B  -> host_wr_*   |  |   |
  |  |   PCI Voodoo BAR0 trap        |                        |  |  AR/R    -> host_rd_*   |  |   |
  |  |        |                      |   M_AXI_HPM0_LPD       |  | S_AXI_STAT (AXI4-Lite)  |  |   |
  |  |        v                      |   @0x8001_0000 (64KB)  |  |  busy/scan_*/init_en    |  |   |
  |  |  voodoo.c VoodooRendererOps   |<======================>|  +-----------+-------------+  |   |
  |  |   VOODOO_BACKEND=hw           |   (status, no drain)   |              |                |   |
  |  |   -> voodoo_hw.cpp            |                        |   host_wr_*/host_rd_*/       |   |
  |  |     bar_write/bar_read        |                        |   busy/scan_*/init_enable    |   |
  |  |     drain()  -> poll STAT     |                        |              v                |   |
  |  |     scanout()-> read DDR fb   |                        |  +-------------------------+  |   |
  |  +-------------------------------+                        |  |     voodoo_top          |  |   |
  |             ^                                             |  | host_if(64-deep FIFO)   |  |   |
  |             |  read front buffer (565)                    |  | cmd_dispatch -> raster, |  |   |
  |             |                                             |  | tmu, pixel_pipe, lfb,   |  |   |
  |  +----------+-------------------+    S_AXI_HP0_FPD         |  | fastfill, fb_arb        |  |   |
  |  |        PS DDR4 (2 GB)        |<========================|  |   tex_ram -> on-chip URAM|  |   |
  |  |  fb region (4 MB) @FB_BASE   |   fb_ddr_adapter (M)    |  |   fb_ram  -> fb_ddr_adptr|  |   |
  |  +-----------------------------+                          |  +-------------------------+  |   |
  |                                                           +-------------------------------+   |
  |   clk_wiz (pl_clk0 100MHz -> 50MHz bring-up) ; proc_sys_reset (sync-deassert) -> clk/rst_n    |
  +----------------------------------------------------------------------------------------------+
```

---

## 2. The 16 MB AXI address map (S_AXI_BAR)

Host byte address `A` arrives at the wrapper; `voodoo_top` consumes `A[23:2]` (dword granularity, `A[1:0]` dropped). Region select is `A[23:22]` and is decoded **inside** `voodoo_top`/`reg_decode` — the wrapper is a pure conduit, passing `A[23:2]` straight through.

| Region | Byte range | A[23:22] | Sub-encoding | Notes |
|---|---|---|---|---|
| Registers | `0x000000..0x3FFFFF` | `00` | `A[9:2]`=regnum, `A[13:10]`=chipmask(0→0xf) | `A[20]`=swizzle-write select, `A[21]`=alias select — **keep CLEAR** |
| LFB | `0x400000..0x7FFFFF` | `01` | `A[21:2]`=lfb dword offset | byte-enables honored (`WSTRB`→`host_wr_be`) |
| Texture | `0x800000..0xFFFFFF` | `1x` | `A[22:2]`=tex dword offset | WRITE-ONLY; region-1x reads return `0xFFFFFFFF` |

Op → BAR-offset arithmetic the shim reproduces verbatim (from `voodoo_rtl.cpp`):
- `reg_write`: `off = (((chipmask&0xf)<<8) | (regnum&0xff)) << 2`. Also shadow `vr->regs[regnum]=data`; if `regnum==0x4a` (`REG_swapbufferCMD`) set dirty.
- `reg_read`: `off = (regnum&0xff) << 2` (chipmask 0 on reads).
- `lfb_write`/`lfb_read`: `0x400000 + (dwoff<<2)`.
- `tex_write`: `0x800000 + (dwoff<<2)`.
- **Do NOT set byte bits 20/21** — `voodoo.c` already resolved swizzle/alias (they fall in dword-offset bits 18/19, which are inherently clear since `dwoff = (chipmask<<8)|regnum ≤ 0xFFF`).

**STATUS read** = byte offset `0x000000` (region 00, regnum 0). This is the only fast BAR read (immediate); every other BAR read **drains the entire command FIFO and all engines** before responding (`host_if.sv:67`: `count_q==0 && ~engines_busy`), latency is unbounded. Route all polling/dims/scanout-descriptor reads to **S_AXI_STAT**, not the BAR.

### S_AXI_STAT sideband (AXI4-Lite, never drains)

| Offset | Reg | Contents |
|---|---|---|
| 0x00 | BUSY | `{31'b0, busy}` |
| 0x04 | FRONTBUF | `{30'b0, dbg_frontbuf[1:0]}` |
| 0x08 | SCAN_FRONT_BASE | `{(32-FB_AW)'b0, scan_front_base[FB_AW-1:0]}` — **WORD** offset (FB_AW=21) |
| 0x0C | SCAN_ROWPIXELS | `{21'b0, scan_rowpixels[10:0]}` |
| 0x10 | SCAN_WIDTH | `{22'b0, scan_width[9:0]}` |
| 0x14 | SCAN_HEIGHT | `{22'b0, scan_height[9:0]}` |
| 0x18 | INIT_ENABLE (RW) | drives `voodoo_top.init_enable[31:0]` (only bit2 live) |

SCAN_FRONT_BASE is **FB_AW-parameterized**, not a hard `0x1FFFFF` mask — so an M7 FB_AW change does not silently truncate.

---

## 3. Memory plan (corrected — DDR4 framebuffer)

**Ground-truth fit (Vivado 2025.2 OOC synth on `xck26-sfvc784-2LV-c`, RAMs black-boxed):** datapath LUT 32,732/117,120 (28.0%), FF 22,241/234,240 (9.5%), DSP 229/1,248 (18.4%), BRAM 0, URAM 0. The fabric datapath fits with huge headroom; there is ample room for the AXI wrapper.

**On-chip memory budget (`xck26`):** 64 URAM (288 Kb each) = 18.9 Mb = 2.36 MB; 144 BRAM36 = 5.3 Mb = 0.66 MB; total = 24.2 Mb = 3.02 MB.

**Why "both on-chip" is impossible (the earlier plan was wrong):**
- FB `FB_AW=21` (2M×16 = 33.6 Mb) needs **512 URAM** (8× over). The framebuffer alone exceeds total on-chip memory.
- The earlier "packed 512×384×3 = 1.125 MiB" figure was an arithmetic error: 3×393,216 words × 2 B = **2.36 MiB (18.9 Mb)** = 288 URAM — still 4.5× over.
- `TEX_AW=20` (full 2 MiB = 16.8 Mb) needs **256 URAM** — does NOT fit. The M7 "restore TEX_AW=20 in URAM" idea is also impossible on this part.
- The ZU15EG OOC report says it plainly: on-chip "would not fit and is the wrong architecture. External DDR4 is correct."

**Adopted plan (first deployable config = "M6"):**
- **Framebuffer → PS DDR4.** Replace the `fb_ram` instance with `fb_ddr_adapter` (AXI4 master → S_AXI_HP0_FPD into PS DRAM). This **requires the `fb_arb.sv` rewrite** (multi-entry tag FIFO + AXI-read-response-driven `cN_rsp_valid` + response backpressure) that was previously deferred — it is mandatory for any on-board bring-up, because the framebuffer cannot be on-chip. There is no "zero new latency-insensitive RTL" milestone on this part; that is the headline scope correction.
- **Texture → on-chip URAM, reduced.** Max on-chip texture is `TEX_AW=18` (256K×16 = 4.2 Mb = exactly 64 URAM, consuming the entire URAM column) or `TEX_AW=17` (128K×16 = 2.1 Mb = 32 URAM, leaving 32 URAM + all BRAM for FIFOs). **Recommend `TEX_AW=17` for bring-up** to leave URAM for the DDR adapter FIFOs and keep timing/placement loose; raise to 18 only if a game needs it. `TEX_AW` is width-clean across `tex_ram.sv`, `tmu.sv`, `tex_dl.sv`, `voodoo_top.sv`. Keeping texture on-chip preserves the 1-cycle `tex_ram` read contract that `tmu.sv`'s `S_ADDR→S_RDLAT` FSM assumes — **no TMU FSM change, no texel cache** needed.
- Add `(* ram_style="ultra" *)` to `tex_ram.sv`'s `mem`. **Verify in the synth report** that the dual-port byte-write (`we[1:0]`) 16-bit-wide array infers true-dual-port URAM and does not cascade into BRAM. This is the single biggest texture-inference risk.
- Texture larger than 256K×16 (TEX_AW>18) must also go to DDR — out of scope for first bring-up.

**fb_arb rewrite contract (highest-risk RTL item):** keep the per-client `cN_req_valid/ready/we/addr/wdata → cN_rsp_valid/rsp_rdata` interface so `pixel_pipe`/`lfb_unit`/`fastfill` need no FSM change, but: (a) `cN_req_ready` becomes "write/cmd FIFO not full"; (b) replace the 1-deep `rd_pend_q/rd_cli_q` tag pipe with a multi-entry tag FIFO carrying client id; (c) drive `cN_rsp_valid` from the actual AXI read-response return; (d) enforce in-order responses (single ARID or per-client ID with reorder). Re-verify `fastfill.sv` and `lfb_unit.sv` tolerate variable latency/stall before committing.

**Scanout / fb readback on hardware:** `scan_front_base` is a 16-bit **WORD** offset. DDR byte address of fb word `W` = `FB_BASE + W*2` (off-by-2× corrupts the whole image). The shim reads the visible window (`rowpixels*height` words) from DDR — ideally one `memcpy`/DMA of the window per frame, then 565→8888 in software, NOT 307,200 single MMIO reads per frame. Read only between swaps (poll STAT busy=0) to avoid contending with the render clients on the HP port.

---

## 4. Clocking and reset

- **Single clock domain.** `voodoo_top` is strictly single-clock + single reset (every submodule `.clk(clk)/.rst_n(rst_n)`). Drive `clk` from a Clocking Wizard MMCM fed by PS `pl_clk0` (100 MHz). **Bring up at 50 MHz** (100/2) — conservative, not the 85 MHz ZU15EG figure (that was a faster/bigger `-2` part; KV260 is `-2LV`, a slower low-voltage bin, and will be more congested once URAM + the fb_arb read-mux are placed). Push the clock up only after a real `xck26-2LV` impl with URAM + DDR adapter closes timing with margin. The OOC 4.0 ns/85 MHz number was datapath-only with no memory synthesized and does not transfer.
- **No host-port CDC.** Drive `maxihpm0_lpd_aclk`, the interconnect/SmartConnect ACLK, `axi_voodoo_slave` ACLK, and `voodoo_top.clk` **all from the same `clk_wiz` output**. Assert in `validate_bd_design` that SmartConnect inserts **no** AXI Clock Converter; if it does, you have an undeclared CDC — either fix the clocking or insert an explicit AXI Clock Converter and document that the converter (not `host_if`) owns the CDC.
- **DDR adapter CDC is real and lives in `fb_ddr_adapter`.** The MIG/HP UI clock differs from `clk`; the adapter's async R/W FIFOs own that crossing entirely. `voodoo_top` never straddles two clocks.
- **Reset is SYNCHRONOUS active-low** (verified: `host_if.sv:79` and all submodules are `always_ff @(posedge clk) if(!rst_n)`; there are no async-reset blocks). Source `rst_n` from `proc_sys_reset` `peripheral_aresetn` (async-assert / sync-deassert) — feeding a sync-reset fabric is safe. **Do NOT reuse `voodoo_ooc.xdc`'s `set_false_path -from [get_ports rst_n]`** — that is correct only for a true async reset; here `rst_n` is a timed signal fanning into thousands of FF D-side enables and must be TIMED. Write a fresh `fpga/kv260/voodoo_kv260.xdc` (the OOC XDC references a top-level `clk` port that does not exist in the BD). `proc_sys_reset`: `slowest_sync_clk = clk_wiz/clk_out1`, `ext_reset_in = pl_resetn0`, `dcm_locked = clk_wiz/locked`.

---

## 5. Throughput reality (set expectations, measure early)

QEMU dispatches **every** BAR access as a separate single-dword `MemoryRegionOps` call (`impl.min/max_access_size=4`, RMW for narrower). The shim's `bar_write` is one volatile store per call, so the AXI master is the A53 doing individual non-cacheable stores — the interconnect sees **single-beat (AWLEN=0)** transactions, not INCR bursts. The wrapper's burst-unroll FSM is a correctness-completeness feature, **not** the throughput mechanism. Do not claim "bursting amortizes texture downloads" — it is false for this software path.

On A53 TCG each guest store is a software MMIO trap (~hundreds of ns) before the AXI store; expect single-MB/s to low-tens-of-MB/s. A 2 MB texmem refill is hundreds of ms; per-frame LFB blits will be slow. **This is functional but slow** (accepted per project goal). Mitigations, in order of value, scoped as follow-on work: (B) a shim-side write-combining coalescer that detects ascending dword offsets in tex/LFB and emits one INCR burst (or memcpy to a write-combining aperture), flushing before any `reg_write`/`reg_read` to preserve FIFO order; (C) a host-driven PL DMA engine for bulk upload (HOST→PL — does not reintroduce guest-visible DMA). Add an explicit acceptance test that times a 2 MB texmem fill and a 640×480 LFB blit and records dwords/s as a go/no-go gate.

Pin the mmap memory type: use UIO (`generic-uio`, Device memory) as the correct path; for the `/dev/mem` fallback require `O_SYNC` and add an `asm volatile DMB` (not just a compiler barrier) after each cmd-FIFO store, since a compiler barrier alone does not enforce arm64 ordering to Device/NC memory.

---

## 6. Bring-up checklist (RTL wrapper → running GLQuake)

1. **(GATE) Fit + inference check.** Synth-only run on `xck26-sfvc784-2LV-c` with `TEX_AW=17`, `(* ram_style="ultra" *)` on `tex_ram`, fb_ram replaced by the DDR adapter stub. Confirm: texture fits ≤ 64 URAM **and** infers true-dual-port byte-write URAM (no BRAM cascade). If not, drop to `TEX_AW=16` or move texture to DDR too. Boot/clk planning is wasted if memory is infeasible.
2. **Write `fpga/kv260/rtl/axi_voodoo_slave.sv`** (S_AXI_BAR AXI4 + S_AXI_STAT AXI4-Lite). Bench against a SystemVerilog testbench replaying `voodoo_rtl.cpp` traffic; verify the AXI-protocol fixes (latched RDATA/held RVALID, AR-gate on wrapper R-beat retirement, AWSIZE!=2 → SLVERR, INCR-only burst, single B terminator).
3. **Write `fpga/kv260/rtl/fb_ddr_adapter.sv` + rewrite `rtl/fb_arb.sv`** for variable AXI read latency. Co-sim the rewritten arbiter against the existing Verilator gold (`make test`) using a latency-injecting fb stub to prove `pixel_pipe`/`lfb_unit`/`fastfill` tolerate stalls and out-of-order-tolerant tagging. **`make test` is the gate — RTL must stay byte-identical to gold.**
4. **Build the Vivado BD** (`fpga/kv260/bd_voodoo.tcl`): Zynq US+ PS (board preset, M_AXI_HPM0_LPD enabled, S_AXI_HP0_FPD enabled for DDR fb, pl_clk0=100MHz, pl_resetn0), clk_wiz→50MHz, proc_sys_reset, SmartConnect (single clock), `axi_voodoo_slave` + `voodoo_top` RTL cells, `fb_ddr_adapter` → HP0. Assign S_AXI_BAR @ `0x8000_0000`/16M, S_AXI_STAT @ `0x8001_0000`/64K. `validate_bd_design`; confirm no clock converter inserted.
5. **Implement** to `write_bitstream` with the fresh `voodoo_kv260.xdc` (timed reset, create_clock auto from clk_wiz). Run place+route and confirm 50 MHz closes with margin before raising the clock. Output `voodoo_bd_wrapper.bit`.
6. **Package**: `voodoo.bit.bin` (header-stripped), `voodoo.dtbo` (`&fpga_full { firmware-name="voodoo.bit.bin"; }` + `generic-uio` nodes for BAR @0x80000000/16M and STAT @0x80010000/64K under the overlay's fpga-region), `shell.json` (`{"shell_type":"XRT_FLAT","num_slots":"1"}`). Stage in `/lib/firmware/xilinx/vvvdoo/`.
7. **Load PL**: `xmutil unloadapp` then `xmutil loadapp vvvdoo` (expected non-fatal warnings — capture them). Verify `xmutil listapps` enumerates `vvvdoo`.
8. **Reach the slave from userspace**: PRIMARY path = `/dev/mem` + `mmap(0x80000000, 16M, O_SYNC)` (needs root, Device/uncached) — the realistic first bring-up. UIO (`/dev/uio0` BAR, `/dev/uio1` STAT) is the hardening step; it requires editing the SOM boot config to add `uio_pdrv_genirq.of_id=generic-uio`, which is the riskiest boot step — gate it behind a working `/dev/mem` path.
9. **Write `cosim/voodoo_hw.cpp`** (the `VOODOO_BACKEND=hw` backend) and `cosim-lib-hw` Makefile target (libvoodoohw.a, no Verilator). Extend `voodoo.c` backend select for `=="hw"` → `voodoo_hw_create()`.
10. **Smoke test the host path** over AXI: write `init_enable`, write fbiInit regs, read back STATUS via STAT sideband, confirm `busy` toggles, fastfill a buffer, read it back from DDR.
11. **Run GLQuake**: launch QEMU with `VOODOO_BACKEND=hw`, point the shim at `/dev/mem` (or `/dev/uio*`) + the DDR fb region. `take_dirty` keys on `REG_swapbufferCMD`; QEMU's ~60 Hz vblank calls `scanout`, which reads the front buffer from DDR and blits to the DisplayPort surface.
12. **Measure throughput** (step 5 of §5 gate); if GLQuake startup texture load takes >1–2 s, implement the coalescer / DMA upload before declaring the milestone done. Deferred (M7+): a real PL video pipeline (VDMA/VTG → DisplayPort) instead of CPU readback.