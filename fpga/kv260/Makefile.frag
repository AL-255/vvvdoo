# Makefile.frag — KV260 board-deployment targets.
# Fold into the top Makefile with:  include fpga/kv260/Makefile.frag
# (kept separate so the board flow never perturbs the verified `make test` gate;
#  the KV260 RTL lives in fpga/kv260/rtl/, OUT of the rtl/*.sv glob.)

VOODOO_INC := $(abspath vvvdoo-refs/06-qemu-voodoo/src)
KV260_RTL  := $(wildcard fpga/kv260/rtl/*.sv)

.PHONY: kv260-lint kv260-fit kv260-pl-fit kv260-impl kv260-view kv260-bit kv260-pkg kv260-install cosim-lib-hw

# lint the WHOLE board PL IP (axi_voodoo_slave + board voodoo_top + fb_ddr_adapter)
# in its real config; does not touch the core `make lint`.
kv260-lint:
	$(VERILATOR) --lint-only -Wall --top-module voodoo_pl_top \
	  +define+VOODOO_INT +define+VOODOO_FB_DDR +define+VOODOO_TEX_AW=17 \
	  rtl/voodoo_lint.vlt rtl/voodoo_pkg.sv $(filter-out rtl/voodoo_pkg.sv,$(wildcard rtl/*.sv)) \
	  fpga/kv260/rtl/axi_voodoo_slave.sv fpga/kv260/rtl/fb_ddr_adapter.sv fpga/kv260/rtl/voodoo_pl_top.sv

# texture URAM-inference GATE (README §6 step 1): synth-only, reduced texture
kv260-fit:
	vivado -mode batch -source fpga/kv260/fit_check.tcl
	@echo "see fpga/reports/kv260_fit_util.rpt (URAM <= 64, no BRAM cascade)"

# REAL board fabric fit: OOC synth of the full PL IP (voodoo_pl_top) on xck26
kv260-pl-fit:
	vivado -mode batch -source fpga/kv260/synth_pl_top.tcl
	@echo "see fpga/reports/kv260_pl_util.rpt"

# full OOC implementation (synth -> place -> route) + placement dump for the view
kv260-impl:
	vivado -mode batch -source fpga/kv260/impl_pl_top.tcl
	@echo "see fpga/reports/kv260_impl_{util,timing}.rpt + kv260_placement.txt"

# render the hierarchy-colored device view PNG from the placement dump.
# Needs Pillow (pip install Pillow); text uses Liberation Sans (Arial-compatible).
kv260-view:
	python3 fpga/kv260/plot_device.py fpga/reports/kv260_placement.txt fpga/kv260/device_view.png

# build the block design + bitstream (needs the M7 RTL — see bd_voodoo.tcl header)
kv260-bit:
	vivado -mode batch -source fpga/kv260/bd_voodoo.tcl

# host-side AXI backend for QEMU (no Verilator, no RTL); VOODOO_BACKEND=hw selects it
cosim-lib-hw: $(BUILD)/libvoodoohw.a
$(BUILD)/libvoodoohw.a: cosim/voodoo_hw.cpp | $(BUILD)
	$(CXX) -std=c++17 -O2 -fPIC -I$(VOODOO_INC) -c $< -o $(BUILD)/voodoo_hw.o
	ar rcs $@ $(BUILD)/voodoo_hw.o

# package the accelerated app (.bit.bin + .dtbo + shell.json) into /lib/firmware
kv260-pkg:
	bootgen -image fpga/kv260/voodoo.bif -arch zynqmp -o fpga/kv260/voodoo.bit.bin -w
	dtc -@ -O dtb -o fpga/kv260/voodoo.dtbo fpga/kv260/voodoo.dts

kv260-install:
	install -d /lib/firmware/xilinx/vvvdoo
	install fpga/kv260/voodoo.bit.bin fpga/kv260/voodoo.dtbo fpga/kv260/shell.json \
	        /lib/firmware/xilinx/vvvdoo/
	@echo "load: xmutil unloadapp; xmutil loadapp vvvdoo"
	@echo "run : VOODOO_BACKEND=hw <qemu launch with the Voodoo device>"
