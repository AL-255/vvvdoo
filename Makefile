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

.PHONY: all gold traces lint sim test-m1 test-m2 test-m3 test-m4 test unit clean cosim cosim-run

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

gold: $(BUILD)/libvgold.a $(BUILD)/vgold_replay $(BUILD)/tracegen

traces: gold
	mkdir -p tb/traces/golden
	$(BUILD)/tracegen tb/traces

# ---------------- RTL ----------------
lint: $(RTL_SRCS) $(RTL_CFG)
	$(VERILATOR) --lint-only -Wall --top-module $(RTL_TOP) $(RTL_CFG) $(RTL_SRCS)

VSIM_FLAGS := --cc --exe --build -O3 -j 0 --assert --top-module $(RTL_TOP) \
              -CFLAGS "-std=c++17 -O2 -I$(abspath model)" \
              -LDFLAGS "$(abspath $(BUILD))/libvgold.a -lm"
ifeq ($(WAVES),1)
VSIM_FLAGS += --trace-fst
endif

sim: $(RTL_SRCS) $(RTL_CFG) tb/frame/tb_main.cpp $(BUILD)/libvgold.a
	$(VERILATOR) $(VSIM_FLAGS) -Mdir $(BUILD)/vsim_obj -o vsim \
	    $(RTL_CFG) $(RTL_SRCS) $(abspath tb/frame/tb_main.cpp)
	cp $(BUILD)/vsim_obj/vsim $(BUILD)/vsim

test-m1: sim traces
	$(BUILD)/vsim tb/traces/m1_fill_lfb.vvt

test-m2: sim traces
	$(BUILD)/vsim tb/traces/m2_tri_gouraud.vvt

test-m3: sim traces
	$(BUILD)/vsim tb/traces/m3_selftest_full.vvt

test-m4: sim traces
	$(BUILD)/vsim tb/traces/m4_pipeline.vvt

# ---------------- RTL-C co-simulation harness ----------------
COSIM_FLAGS := --cc --exe --build -O3 -j 0 --top-module $(RTL_TOP) \
               -CFLAGS "-std=c++17 -O2"
cosim: $(RTL_SRCS) $(RTL_CFG) cosim/cosim_replay.cpp
	$(VERILATOR) $(COSIM_FLAGS) -Mdir $(BUILD)/cosim_obj -o cosim_replay \
	    $(RTL_CFG) $(RTL_SRCS) $(abspath cosim/cosim_replay.cpp)
	cp $(BUILD)/cosim_obj/cosim_replay $(BUILD)/cosim_replay

cosim-run: cosim traces
	$(BUILD)/cosim_replay tb/traces/m3_selftest_full.vvt $(BUILD)/cosim_m3

# ---------------- unit tests ----------------
UNIT_SRCS := $(wildcard tb/unit/*.cpp)
UNIT_BINS := $(patsubst tb/unit/%.cpp,$(BUILD)/unit_%,$(UNIT_SRCS))

$(BUILD)/unit_%: tb/unit/%.cpp $(BUILD)/libvgold.a
	$(CXX) $(CXXFLAGS) -Imodel $< $(BUILD)/libvgold.a -lm -o $@

unit: $(UNIT_BINS)
	@set -e; for t in $(UNIT_BINS); do echo "== $$t"; $$t; done

test: unit test-m1 test-m2 test-m3 test-m4

clean:
	rm -rf $(BUILD)
