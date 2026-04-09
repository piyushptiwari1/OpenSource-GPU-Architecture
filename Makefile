.PHONY: test compile

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)
export COCOTB_LIB_DIR=$(shell cocotb-config --lib-dir)
LIBPYTHON_DIR=$(shell dirname $(shell cocotb-config --libpython))

test_%:
	make compile
	iverilog -o build/sim.vvp -s gpu -g2012 build/gpu.v
	PYGPI_PYTHON_BIN=$$(cocotb-config --python-bin) \
	LD_LIBRARY_PATH="$(LIBPYTHON_DIR):$$LD_LIBRARY_PATH" \
	COCOTB_TEST_MODULES=test.test_$* \
	vvp -M $$(cocotb-config --lib-dir) -m libcocotbvpi_icarus build/sim.vvp

compile:
	make compile_alu
	sv2v -I src/* -w build/gpu.v
	echo "" >> build/gpu.v
	cat build/alu.v >> build/gpu.v
	echo '`timescale 1ns/1ns' > build/temp.v
	cat build/gpu.v >> build/temp.v
	mv build/temp.v build/gpu.v

compile_%:
	sv2v -w build/$*.v src/$*.sv

# TODO: Get gtkwave visualizaiton

show_%: %.vcd %.gtkw
	gtkwave $^
