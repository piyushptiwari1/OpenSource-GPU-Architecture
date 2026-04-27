.PHONY: test compile clean

export LIBPYTHON_LOC=$(shell cocotb-config --libpython)
export PYGPI_PYTHON_BIN=$(shell cocotb-config --python-bin)

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
	COCOTB_TEST_MODULES=$(if $(MODULE),$(MODULE),test.test_$*) vvp -M $$(cocotb-config --lib-dir) -m libcocotbvpi_icarus build/sim.vvp -fst > test/runs/test_$*_$(TIMESTAMP).out

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
