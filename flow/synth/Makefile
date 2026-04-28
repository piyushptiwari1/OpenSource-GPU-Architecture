# Generic synthesizability check for tiny-gpu.
#
# Goal: prove `gpu` (src/gpu.sv + dependencies) elaborates and
# synthesizes to a generic gate netlist.  This is the canonical
# CI-gating physical-flow check.
#
# Yosys' native SystemVerilog frontend can't handle unpacked array
# ports; we use sv2v (Haskell-based, /usr/local/bin/sv2v in the
# toolchain image) as a preprocessor first, the same as the iverilog
# simulation flow.
#
# Outputs:
#   build/gpu.v             flat Verilog after sv2v
#   build/gpu.json          yosys synth output
#   build/yosys.log         yosys log
#   build/synth.stat.txt    cell-count summary
#
# Usage (from repo root):
#   make -C flow/synth

REPO_ROOT  := $(abspath $(CURDIR)/../..)
BUILD_DIR  := $(CURDIR)/build
TOP        := gpu

SRCS_SV    := \
  $(REPO_ROOT)/src/alu.sv \
  $(REPO_ROOT)/src/controller.sv \
  $(REPO_ROOT)/src/core.sv \
  $(REPO_ROOT)/src/dcr.sv \
  $(REPO_ROOT)/src/decoder.sv \
  $(REPO_ROOT)/src/dispatch.sv \
  $(REPO_ROOT)/src/fetcher.sv \
  $(REPO_ROOT)/src/gpu.sv \
  $(REPO_ROOT)/src/lsu.sv \
  $(REPO_ROOT)/src/pc.sv \
  $(REPO_ROOT)/src/registers.sv \
  $(REPO_ROOT)/src/scheduler.sv

V          := $(BUILD_DIR)/gpu.v
JSON       := $(BUILD_DIR)/gpu.json
STAT       := $(BUILD_DIR)/synth.stat.txt
LOG        := $(BUILD_DIR)/yosys.log

.PHONY: all clean

all: $(STAT)

$(BUILD_DIR):
	mkdir -p $@

$(V): $(SRCS_SV) | $(BUILD_DIR)
	sv2v -I $(REPO_ROOT)/src -w $@ $(SRCS_SV)

$(JSON): $(V) | $(BUILD_DIR)
	yosys -q -l $(LOG) \
	      -p "read_verilog $(V); \
	          hierarchy -check -top $(TOP); \
	          proc; opt; fsm; opt; memory; opt; \
	          techmap; opt; \
	          abc -fast; \
	          opt -fast; \
	          check -assert; \
	          write_json $(JSON)"

$(STAT): $(JSON)
	yosys -q -p "read_json $(JSON); stat -top $(TOP)" | tee $@

clean:
	rm -rf $(BUILD_DIR)
