# vvvdoo — root build. See docs/CONTRACTS.md §10.
SHELL := /bin/bash
BUILD := build

CC      ?= gcc
CXX     ?= g++
CFLAGS  := -std=c11 -O2 -g -Wall -Wextra -Werror
CXXFLAGS:= -std=c++17 -O2 -g -Wall -Wextra -Werror
VERILATOR ?= verilator

# package must precede importers on the verilator command line
RTL_PKG  := rtl/voodoo_pkg.sv
RTL_SRCS := $(RTL_PKG) $(filter-out $(RTL_PKG),$(wildcard rtl/*.sv))
RTL_CFG  := $(wildcard rtl/*.vlt)
RTL_TOP  := voodoo_top

# INT=1 builds the fixed-point (VOODOO_INT) datapath: appends +define+VOODOO_INT to
# every verilator invocation (lint/sim/cosim/cosim-lib). INT=0 (default) is the float
# datapath that is pixel-exact vs the gold model — the `make test` contract.
# Verilator obj dirs and output binaries are SUFFIXED with $(INT) so the float and int
# artifacts coexist (the RMSE harness needs both at once) and a stale INT toggle can
# never silently reuse the wrong generated C++.
INT   ?= 0
VDEFS :=
ifeq ($(INT),1)
VDEFS += +define+VOODOO_INT
endif

.PHONY: all gold traces lint sim test-m1 test-m2 test-m3 test-m4 test-m5 test unit clean cosim cosim-run cosim-lib rmse

all: gold traces lint sim

# ---------------- golden model ----------------
$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/voodoo_gold.o: model/voodoo_gold.c model/voodoo_gold.h | $(BUILD)
	$(CC) $(CFLAGS) -Imodel -c $< -o $@

$(BUILD)/libvgold.a: $(BUILD)/voodoo_gold.o
	ar rcs $@ $^

$(BUILD)/vgold_replay: tools/vgold_replay.c $(BUILD)/libvgold.a
	$(CC) $(CFLAGS) -Imodel $< $(BUILD)/libvgold.a -lm -o $@

$(BUILD)/tracegen: tools/tracegen.c $(BUILD)/libvgold.a
	$(CC) $(CFLAGS) -Imodel $< $(BUILD)/libvgold.a -lm -o $@

# RMSE/PSNR metric tool — dependency-free C11, links -lm only (NOT libvgold; it is a pure
# PPM comparator used for int-vs-float, int-vs-gold, and rtl-vs-gold image diffs).
$(BUILD)/ppm_rmse: tools/ppm_rmse.c | $(BUILD)
	$(CC) $(CFLAGS) $< -lm -o $@

gold: $(BUILD)/libvgold.a $(BUILD)/vgold_replay $(BUILD)/tracegen

traces: gold
	mkdir -p tb/traces/golden
	$(BUILD)/tracegen tb/traces

# ---------------- RTL ----------------
lint: $(RTL_SRCS) $(RTL_CFG)
	$(VERILATOR) --lint-only -Wall --top-module $(RTL_TOP) $(VDEFS) $(RTL_CFG) $(RTL_SRCS)

VSIM_FLAGS := --cc --exe --build -O3 -j 0 --assert --top-module $(RTL_TOP) \
              -CFLAGS "-std=c++17 -O2 -I$(abspath model)" \
              -LDFLAGS "$(abspath $(BUILD))/libvgold.a -lm"
ifeq ($(WAVES),1)
VSIM_FLAGS += --trace-fst
endif

sim: $(RTL_SRCS) $(RTL_CFG) tb/frame/tb_main.cpp $(BUILD)/libvgold.a
	$(VERILATOR) $(VSIM_FLAGS) -Mdir $(BUILD)/vsim_obj$(INT) -o vsim$(INT) \
	    $(VDEFS) $(RTL_CFG) $(RTL_SRCS) $(abspath tb/frame/tb_main.cpp)
	cp $(BUILD)/vsim_obj$(INT)/vsim$(INT) $(BUILD)/vsim$(INT)

# `make test` is an INT=0-only contract (the gold model is float; INT=1 is judged by RMSE,
# never by test). The test-mN recipes run the unsuffixed $(BUILD)/vsim: build it via the
# INT=0 sim and alias vsim0 -> vsim so the test command lines stay unchanged.
.PHONY: vsim
vsim:
	$(MAKE) sim INT=0
	cp $(BUILD)/vsim0 $(BUILD)/vsim

test-m1: vsim traces
	$(BUILD)/vsim tb/traces/m1_fill_lfb.vvt

test-m2: vsim traces
	$(BUILD)/vsim tb/traces/m2_tri_gouraud.vvt

test-m3: vsim traces
	$(BUILD)/vsim tb/traces/m3_selftest_full.vvt

test-m4: vsim traces
	$(BUILD)/vsim tb/traces/m4_pipeline.vvt

test-m5: vsim traces
	$(BUILD)/vsim tb/traces/m5_texfmt.vvt

# DDR-readiness check: rebuild the trace-diff with the FB_LAT_INJECT memory model
# (variable read latency + back-pressure on the fb port) and require all five
# frames to stay byte-identical to gold -- proves the fb_arb tag FIFO and the
# lfb/fastfill/pixel_pipe clients tolerate PS-DDR4 latency before real DDR exists.
.PHONY: test-fblat
test-fblat: $(RTL_SRCS) $(RTL_CFG) tb/frame/tb_main.cpp $(BUILD)/libvgold.a traces
	$(VERILATOR) $(VSIM_FLAGS) -Mdir $(BUILD)/vsim_objfblat -o vsimfblat \
	    +define+FB_LAT_INJECT $(RTL_CFG) $(RTL_SRCS) $(abspath tb/frame/tb_main.cpp)
	@set -e; for t in m1_fill_lfb m2_tri_gouraud m3_selftest_full m4_pipeline m5_texfmt; do \
	  echo "== fblat $$t"; $(BUILD)/vsim_objfblat/vsimfblat tb/traces/$$t.vvt; done

# End-to-end functional verification of fb_ddr_adapter: build the trace-diff with
# the adapter -> behavioral AXI memory (axi_mem_sim) -> fb_ram loop and require all
# five frames byte-identical to gold. Verifies the adapter's AXI4 FSM + narrow
# (2-byte) addressing + lane muxing without Vivado. Board RTL added to the build.
.PHONY: test-fbddr
test-fbddr: $(RTL_SRCS) $(RTL_CFG) tb/frame/tb_main.cpp $(BUILD)/libvgold.a traces
	$(VERILATOR) $(VSIM_FLAGS) -Mdir $(BUILD)/vsim_objfbddr -o vsimfbddr \
	    +define+FB_DDR_SIM $(RTL_CFG) $(RTL_SRCS) \
	    $(abspath fpga/kv260/rtl/fb_ddr_adapter.sv) $(abspath fpga/kv260/rtl/axi_mem_sim.sv) \
	    $(abspath tb/frame/tb_main.cpp)
	@set -e; for t in m1_fill_lfb m2_tri_gouraud m3_selftest_full m4_pipeline m5_texfmt; do \
	  echo "== fbddr $$t"; $(BUILD)/vsim_objfbddr/vsimfbddr tb/traces/$$t.vvt; done

# ---------------- RTL-C co-simulation harness ----------------
COSIM_FLAGS := --cc --exe --build -O3 -j 0 --top-module $(RTL_TOP) \
               -CFLAGS "-std=c++17 -O2"
cosim: $(RTL_SRCS) $(RTL_CFG) cosim/cosim_replay.cpp
	$(VERILATOR) $(COSIM_FLAGS) -Mdir $(BUILD)/cosim_obj$(INT) -o cosim_replay$(INT) \
	    $(VDEFS) $(RTL_CFG) $(RTL_SRCS) $(abspath cosim/cosim_replay.cpp)
	cp $(BUILD)/cosim_obj$(INT)/cosim_replay$(INT) $(BUILD)/cosim_replay$(INT)

# cosim-run is the float (INT=0) smoke test; the RMSE harness drives both replay0/replay1.
cosim-run: traces
	$(MAKE) cosim INT=0
	$(BUILD)/cosim_replay0 tb/traces/m3_selftest_full.vvt $(BUILD)/cosim_m3

# ---------------- LIVE QEMU RTL-C co-sim backend (static lib) ----------------
# Verilates the RTL (no testbench), compiles the generated sources + Verilator
# runtime + the VoodooRendererOps bridge, and archives a single static lib the
# QEMU device links against.  VOODOO_INC is the source dir holding
# voodoo_render.h (the ops boundary the bridge implements).
VRTL_OBJDIR := $(BUILD)/vrtl_obj
VRTL_LIB    := $(BUILD)/libvoodoortl.a
VOODOO_INC  := $(abspath vvvdoo-refs/06-qemu-voodoo/src)
VERILATOR_ROOT ?= $(shell $(VERILATOR) --getenv VERILATOR_ROOT)

cosim-lib: $(VRTL_LIB)

$(VRTL_LIB): $(RTL_SRCS) $(RTL_CFG) cosim/voodoo_rtl.cpp | $(BUILD)
	rm -rf $(VRTL_OBJDIR)
	$(VERILATOR) --cc -O3 -j 0 --top-module $(RTL_TOP) \
	    -CFLAGS "-std=c++17 -O2 -fPIC -I$(VOODOO_INC)" \
	    -Mdir $(VRTL_OBJDIR) \
	    $(VDEFS) $(RTL_CFG) $(RTL_SRCS) $(abspath cosim/voodoo_rtl.cpp)
	$(MAKE) -C $(VRTL_OBJDIR) -f V$(RTL_TOP).mk
	@# collect every compiled object (generated RTL + verilated runtime + bridge)
	ar rcs $(VRTL_LIB) $(VRTL_OBJDIR)/*.o
	@echo "cosim-lib: built $(VRTL_LIB)"
	@echo "cosim-lib: Verilator include dir = $(VERILATOR_ROOT)/include"

# ---------------- INT-vs-FLOAT RMSE harness ----------------
# Builds both datapaths (float=cosim_replay0, int=cosim_replay1; suffixed obj dirs so no
# clean is needed between toggles), replays m1..m5 through each, and reports per-frame
# RMSE/PSNR. m1 ~= 0 (fills), m2 small (Gouraud coverage), m5 largest (TMU divide/log2).
rmse: $(BUILD)/ppm_rmse traces
	@$(MAKE) cosim INT=0
	@$(MAKE) cosim INT=1
	@set -e; for t in m1_fill_lfb m2_tri_gouraud m3_selftest_full m4_pipeline m5_texfmt; do \
	  echo "== $$t"; \
	  $(BUILD)/cosim_replay0 tb/traces/$$t.vvt $(BUILD)/float_$$t >/dev/null; \
	  $(BUILD)/cosim_replay1 tb/traces/$$t.vvt $(BUILD)/int_$$t   >/dev/null; \
	  for fp in $(BUILD)/float_$${t}_*.ppm; do \
	    ip=$${fp/float_/int_}; [ -f "$$ip" ] && $(BUILD)/ppm_rmse "$$fp" "$$ip"; \
	  done; \
	done

# ---------------- unit tests ----------------
UNIT_SRCS := $(wildcard tb/unit/*.cpp)
UNIT_BINS := $(patsubst tb/unit/%.cpp,$(BUILD)/unit_%,$(UNIT_SRCS))

$(BUILD)/unit_%: tb/unit/%.cpp $(BUILD)/libvgold.a
	$(CXX) $(CXXFLAGS) -Imodel $< $(BUILD)/libvgold.a -lm -o $@

unit: $(UNIT_BINS)
	@set -e; for t in $(UNIT_BINS); do echo "== $$t"; $$t; done

# ---------------- SRT divider standalone verification ----------------
# Verilates rtl/srt_div.sv on its own with a self-checking C++ harness that
# diffs q/r against C `/`,`%` over directed + 200k random signed-64 vectors.
.PHONY: srt-test srt-test-pipe
srt-test:
	$(VERILATOR) --cc --exe --build -j 0 -Mdir $(BUILD)/srt_obj \
	  --top-module srt_div -Wall -Wno-fatal \
	  rtl/srt_div.sv tb/srt/tb_srt_div.cpp -o srt_div_tb
	$(BUILD)/srt_obj/srt_div_tb

srt-test-pipe:
	$(VERILATOR) --cc --exe --build -j 0 -Mdir $(BUILD)/srt_obj_pipe \
	  --top-module srt_div -GPIPELINED=1 -Wall -Wno-fatal \
	  rtl/srt_div.sv tb/srt/tb_srt_div.cpp -o srt_div_tb_pipe
	$(BUILD)/srt_obj_pipe/srt_div_tb_pipe

test: unit test-m1 test-m2 test-m3 test-m4 test-m5

# FPGA out-of-context synth+impl on Zynq UltraScale+ ZU15EG (integer backend).
# Requires Vivado on PATH. Reports land in fpga/reports/ (see ZU15EG-REPORT.md).
# Override the target period (ns): make fpga FPGA_PERIOD=4.0
FPGA_PERIOD ?= 4.0
.PHONY: fpga
fpga:
	vivado -nojournal -log fpga/reports/vivado.log -mode batch \
	       -source fpga/syn/synth_zu15eg.tcl -tclargs $(FPGA_PERIOD)
	@cat fpga/reports/SUMMARY.txt

# KV260 board-deployment targets (kv260-lint/-fit/-bit/-pkg, cosim-lib-hw).
# Board RTL lives in fpga/kv260/rtl/ (out of the rtl/*.sv glob) so these never
# perturb `make test`. See fpga/kv260/README.md.
include fpga/kv260/Makefile.frag

clean:
	rm -rf $(BUILD)
