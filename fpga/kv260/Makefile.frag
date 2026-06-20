# Makefile.frag — KV260 board-deployment targets.
# Fold into the top Makefile with:  include fpga/kv260/Makefile.frag
# (kept separate so the board flow never perturbs the verified `make test` gate;
#  the KV260 RTL lives in fpga/kv260/rtl/, OUT of the rtl/*.sv glob.)

VOODOO_INC := $(abspath vvvdoo-refs/06-qemu-voodoo/src)
KV260_RTL  := $(wildcard fpga/kv260/rtl/*.sv)

.PHONY: kv260-lint kv260-fit kv260-bit kv260-pkg kv260-install cosim-lib-hw

# lint the board wrappers standalone (does not touch the core make lint)
kv260-lint:
	$(VERILATOR) --lint-only -Wall --top-module axi_voodoo_slave \
	  rtl/voodoo_pkg.sv rtl/voodoo_lint.vlt fpga/kv260/rtl/axi_voodoo_slave.sv

# README §6 step-1 GATE: synth-only fit/inference check on xck26 (TEX_AW reduced)
kv260-fit:
	FIT_ONLY=1 vivado -mode batch -source fpga/kv260/bd_voodoo.tcl
	@echo "see fpga/reports/kv260_fit_util.rpt (URAM <= 64, no BRAM cascade)"

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
