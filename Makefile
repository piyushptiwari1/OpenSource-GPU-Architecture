.PHONY: test compile

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN=$(shell cocotb-config --python-bin)

TIMESTAMP := $(shell date +%Y%m%d%H%M%S)

test_%:
	mkdir -p build
	make compile
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu.v
	cd test && mkdir -p runs
	cd ..
	COCOTB_TEST_MODULES=test.test_$* vvp -M $$(cocotb-config --lib-dir) -m libcocotbvpi_icarus build/sim.vvp -fst > test/runs/test_$*_$(TIMESTAMP).out

clean:
	rm -rf build/* sim_build
	rmdir build 2>/dev/null || true
	rm -rf test/runs/*
	rmdir test/runs 2>/dev/null || true

compile:
	mkdir -p build
	make compile_alu
	sv2v -I src/* -w build/gpu.v
	echo "" >> build/gpu.v
	cat build/alu.v >> build/gpu.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu.v >> build/temp.v
	mv build/temp.v build/gpu.v

compile_%:
	./sv2v/sv2v -w build/$*.v src/$*.sv

# The gtkwave FST file -> sim_build/gpu.fst
test.test_%: compile
	make -f Makefile.cocotb.mk MODULE=$@

show_%: %.vcd %.gtkw
	gtkwave $^
