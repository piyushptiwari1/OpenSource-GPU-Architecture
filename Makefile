.PHONY: test compile clean

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN=$(shell cocotb-config --python-bin)
export COCOTB_LIB_DIR=$(shell cocotb-config --lib-dir)
LIBPYTHON_DIR=$(shell dirname $(shell cocotb-config --libpython))

TOPLEVEL := gpu
TIMESTAMP := $(shell date +%Y%m%d%H%M%S)

# Default test target: builds with iverilog, dumps waveform to VCD,
# logs cocotb output to a timestamped file under test/runs/.
test_%:
	mkdir -p build
	make compile
	make iverilog_dump_$*.sv
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu.v -s iverilog_dump_$* iverilog_dump_$*.sv
	cd test && mkdir -p runs
	cd ..
	LD_LIBRARY_PATH="$(LIBPYTHON_DIR):$$LD_LIBRARY_PATH" \
	COCOTB_TEST_MODULES=$(if $(MODULE),$(MODULE),test.test_$*) \
	MODULE=$(if $(MODULE),$(MODULE),test.test_$*) \
	vvp -M $$(cocotb-config --lib-dir) -m libcocotbvpi_icarus build/sim.vvp -fst > test/runs/test_$*_$(TIMESTAMP).out

# Path to sv2v: prefer vendored binary if present (for users without OSS
# CAD Suite installed), otherwise fall back to whatever is on PATH (e.g.
# the toolchain container ships sv2v in /opt/oss-cad-suite/bin).
SV2V ?= $(if $(wildcard ./sv2v/sv2v),./sv2v/sv2v,sv2v)

# Sources required to elaborate the `gpu` top. Tracing the instance
# hierarchy: gpu -> {dcr, controller, dispatch, core}; core -> {fetcher,
# decoder, scheduler, alu, lsu, registers, pc}. Anything else under
# src/ (display_controller, framebuffer, geometry_engine, …) is part of
# the wider SoC project and is built independently via
# `Makefile.vlsi`. Pulling it into the gpu-top sv2v glob breaks
# compilation because v0.0.13 cannot translate the packed-array port
# patterns those files use.
GPU_TOP_SRCS := \
    src/gpu.sv         \
    src/dcr.sv         \
    src/controller.sv  \
    src/dispatch.sv    \
    src/core.sv        \
    src/fetcher.sv     \
    src/decoder.sv     \
    src/scheduler.sv   \
    src/lsu.sv         \
    src/registers.sv   \
    src/pc.sv

compile:
	mkdir -p build
	make compile_alu
	$(SV2V) -I src -w build/gpu.v $(GPU_TOP_SRCS)
	echo "" >> build/gpu.v
	cat build/alu.v >> build/gpu.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu.v >> build/temp.v
	mv build/temp.v build/gpu.v

compile_%:
	$(SV2V) -w build/$*.v src/$*.sv

# Generate a tiny dumpfile module so iverilog produces a VCD waveform
iverilog_dump_%.sv:
	echo 'module iverilog_dump_$*();' > $@
	echo 'initial begin' >> $@
	echo '    $$dumpfile("$*.vcd");' >> $@
	echo '    $$dumpvars(0, $(TOPLEVEL));' >> $@
	echo 'end' >> $@
	echo 'endmodule' >> $@

# Alternate cocotb-driven flow producing FST waveforms via Makefile.cocotb.mk
test.test_%: compile
	make -f Makefile.cocotb.mk MODULE=$@

.SECONDEXPANSION:

# A .gtkw file is optional
show_%: %.vcd $$(wildcard $$*.gtkw)
	gtkwave $^

clean:
	rm -rf build/* sim_build
	rmdir build 2>/dev/null || true
	rm -rf test/runs/*
	rmdir test/runs 2>/dev/null || true
	rm -f iverilog_dump*
	rm -f *.vcd
