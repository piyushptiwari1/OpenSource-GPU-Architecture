.PHONY: test compile clean lint_verilator formal_smoke coverage_functional

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN=$(shell cocotb-config --python-bin)
export COCOTB_LIB_DIR=$(shell cocotb-config --lib-dir)
LIBPYTHON_DIR=$(shell dirname $(shell cocotb-config --libpython))

TOPLEVEL := gpu
TIMESTAMP := $(shell date +%Y%m%d%H%M%S)

# Tiny Tapeout 7 adapter test (README roadmap item). The adapter is a
# self-contained serial-protocol wrapper (src/tt_um_tiny_gpu.sv) with its own
# small on-chip memories, so it builds independently of the gpu top. This
# explicit rule takes precedence over the test_% pattern rule below.
test_tt_adapter:
	mkdir -p build test/runs
	$(SV2V) -w build/tt_um_tiny_gpu.v src/tt_um_tiny_gpu.sv
	echo '`timescale 1ns/1ns' > build/temp_tt.v
	cat build/tt_um_tiny_gpu.v >> build/temp_tt.v
	mv build/temp_tt.v build/tt_um_tiny_gpu.v
	iverilog -o build/tt_sim.vvp -s tt_um_tiny_gpu -g2012 build/tt_um_tiny_gpu.v
	LD_LIBRARY_PATH="$(LIBPYTHON_DIR):$$LD_LIBRARY_PATH" \
	COCOTB_TEST_MODULES=test.test_tt_adapter \
	MODULE=test.test_tt_adapter \
	vvp -M $$(cocotb-config --lib-dir) -m libcocotbvpi_icarus build/tt_sim.vvp -fst > test/runs/test_tt_adapter_$(TIMESTAMP).out

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
    src/l2_cache.sv    \
    src/dispatch.sv    \
    src/core.sv        \
    src/fetcher.sv     \
    src/icache.sv      \
    src/decoder.sv     \
    src/scheduler.sv   \
    src/lsu.sv         \
    src/shared_memory.sv \
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

# Multi-warp configuration test. cocotb's VPI layer segfaults on iverilog
# parameter overrides (both -P and defparam), so this target rewrites the
# THREADS_PER_WARP *default* in the translated Verilog instead: each 4-thread
# block then runs as 2 independent warps of 2 lanes (true warp scheduling).
# RTL and testbench are otherwise identical to the standard flow.
test_warp_scheduling_e2e:
	mkdir -p build
	make compile
	sed 's/parameter THREADS_PER_WARP = THREADS_PER_BLOCK;/parameter THREADS_PER_WARP = 2;/' build/gpu.v > build/gpu_mw.v
	make iverilog_dump_warp_scheduling_e2e.sv
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu_mw.v -s iverilog_dump_warp_scheduling_e2e iverilog_dump_warp_scheduling_e2e.sv
	cd test && mkdir -p runs
	cd ..
	LD_LIBRARY_PATH="$(LIBPYTHON_DIR):$$LD_LIBRARY_PATH" \
	COCOTB_TEST_MODULES=test.test_warp_scheduling_e2e \
	MODULE=test.test_warp_scheduling_e2e \
	vvp -M $$(cocotb-config --lib-dir) -m libcocotbvpi_icarus build/sim.vvp -fst > test/runs/test_warp_scheduling_e2e_$(TIMESTAMP).out

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

# Fast SystemVerilog syntax/lint sanity pass over the full src tree.
lint_verilator:
	@command -v verilator >/dev/null 2>&1 || { \
		echo "ERROR: verilator not found in PATH"; \
		echo "Install Verilator or use the toolchain container."; \
		exit 2; \
	}
	verilator --lint-only -Wall -Wno-fatal src/gpu_soc.sv src/*.sv

# Functional (MDV) coverage: run the cocotb-coverage-instrumented e2e test,
# which exports test/coverage/functional_coverage.xml and asserts FSM closure.
coverage_functional:
	rm -f build/gpu.v build/temp.v build/sim.vvp iverilog_dump_functional_coverage.sv
	make test_functional_coverage
	@echo "Functional coverage XML: test/coverage/functional_coverage.xml"

# Formal smoke test (current proven set): DCR + scheduler/fetcher/dispatch/lsu/pc
# FSMs + the core cross-module integration proof + the ALU result-correctness.
formal_smoke:
	@command -v sby >/dev/null 2>&1 || { \
		echo "ERROR: sby (SymbiYosys) not found in PATH"; \
		echo "Use OSS CAD Suite or run the documented formal Docker command."; \
		exit 2; \
	}
	rm -rf formal/dcr/dcr
	cd formal/dcr && sby -f dcr.sby
	rm -rf formal/scheduler/scheduler
	cd formal/scheduler && sby -f scheduler.sby
	rm -rf formal/fetcher/fetcher
	cd formal/fetcher && sby -f fetcher.sby
	rm -rf formal/dispatch/dispatch
	cd formal/dispatch && sby -f dispatch.sby
	rm -rf formal/lsu/lsu
	cd formal/lsu && sby -f lsu.sby
	rm -rf formal/pc/pc
	cd formal/pc && sby -f pc.sby
	rm -rf formal/core/core
	cd formal/core && sby -f core.sby
	rm -rf formal/alu/alu
	cd formal/alu && sby -f alu.sby
