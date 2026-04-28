# Open-source ECP5 flow for tiny-gpu (ULX3S target).
# Tools: yosys + nextpnr-ecp5 + ecppack + ecpprog (OSS CAD Suite).

REPO_ROOT  := $(abspath $(CURDIR)/../../..)
BUILD_DIR  := $(CURDIR)/build
DEVICE     := 25k
PACKAGE    := CABGA381
SPEED      := 6
TOP        := gpu_fpga_top
LPF        := gpu_ulx3s.lpf

SRCS_CORE  := \
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

SRCS_TOP   := $(REPO_ROOT)/flow/fpga/common/gpu_fpga_top.sv

JSON       := $(BUILD_DIR)/$(TOP).json
CFG        := $(BUILD_DIR)/$(TOP).config
BIT        := $(BUILD_DIR)/$(TOP).bit

.PHONY: all synth pnr bitstream prog clean

all: bitstream

synth: $(JSON)
pnr: $(CFG)
bitstream: $(BIT)

$(BUILD_DIR):
	mkdir -p $@

$(JSON): $(SRCS_CORE) $(SRCS_TOP) | $(BUILD_DIR)
	yosys -p "read_verilog -sv -defer $(SRCS_CORE) $(SRCS_TOP); \
	          hierarchy -check -top $(TOP); \
	          synth_ecp5 -top $(TOP) -abc9 -json $@" \
	          -l $(BUILD_DIR)/yosys.log

$(CFG): $(JSON) $(LPF) | $(BUILD_DIR)
	nextpnr-ecp5 --$(DEVICE) --package $(PACKAGE) --speed $(SPEED) \
	   --json $(JSON) --lpf $(LPF) --textcfg $@ \
	   --report $(BUILD_DIR)/nextpnr.report.json \
	   --log $(BUILD_DIR)/nextpnr.log

$(BIT): $(CFG)
	ecppack $< $@

prog: $(BIT)
	ecpprog $<

clean:
	rm -rf $(BUILD_DIR)
