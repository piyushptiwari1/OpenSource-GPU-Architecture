# Synthesizability check for the Tiny Tapeout wrapper (C-20 Path A).
#
# Goal: confirm `tt_um_tiny_gpu` elaborates and synthesizes to a
# generic gate netlist with yosys. The full GDS run lives in the
# OpenLane2 config (../tt/config.json) and Tiny Tapeout's own CI;
# this Makefile is the cheap pre-flight gate run on every push.
#
# Outputs:
#   build/tt_um_tiny_gpu.v          flat Verilog after sv2v
#   build/tt_um_tiny_gpu.json       yosys synth output
#   build/yosys.log                 yosys log
#   build/synth.stat.txt            cell-count summary
#
# Usage (from repo root):
#   make -C flow/tt

REPO_ROOT  := $(abspath $(CURDIR)/../..)
BUILD_DIR  := $(CURDIR)/build
TOP        := tt_um_tiny_gpu

# Same dependency list as the OpenLane2 config (config.json).
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
  $(REPO_ROOT)/src/scheduler.sv \
  $(REPO_ROOT)/src/tt_um_tiny_gpu.sv

V          := $(BUILD_DIR)/$(TOP).v
JSON       := $(BUILD_DIR)/$(TOP).json
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
