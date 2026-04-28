# Open-source iCE40 flow for tiny-gpu.
# Tools: yosys + nextpnr-ice40 + icepack + icetime (all in OSS CAD Suite).
#
# Targets:
#   make synth      -> gpu_fpga_top.json   (yosys synth_ice40)
#   make pnr        -> gpu_fpga_top.asc    (nextpnr-ice40 P&R)
#   make bitstream  -> gpu_fpga_top.bin    (icepack bitstream)
#   make timing     -> icetime report
#   make prog       -> iceprog flash       (USB-attached HX8K board)
#   make clean

REPO_ROOT  := $(abspath $(CURDIR)/../../..)
BUILD_DIR  := $(CURDIR)/build
DEVICE     := hx8k
PACKAGE    := ct256
TOP        := gpu_fpga_top
PCF        := gpu_hx8k.pcf

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
ASC        := $(BUILD_DIR)/$(TOP).asc
BIN        := $(BUILD_DIR)/$(TOP).bin
TIMING     := $(BUILD_DIR)/$(TOP).timing.rpt

.PHONY: all synth pnr bitstream timing prog clean

all: bitstream timing

synth: $(JSON)
pnr: $(ASC)
bitstream: $(BIN)
timing: $(TIMING)

$(BUILD_DIR):
	mkdir -p $@

# yosys: synth_ice40 -abc9 picks up SB_RAM block-RAM inference.  We
# pass `-defer` to read_verilog so cross-file module references resolve
# regardless of file order.
$(JSON): $(SRCS_CORE) $(SRCS_TOP) | $(BUILD_DIR)
	yosys -p "read_verilog -sv -defer $(SRCS_CORE) $(SRCS_TOP); \
	         hierarchy -check -top $(TOP); \
	         synth_ice40 -top $(TOP) -abc9 -dffe_min_ce_use 4 -json $@" \
	         -l $(BUILD_DIR)/yosys.log

$(ASC): $(JSON) $(PCF) | $(BUILD_DIR)
	nextpnr-ice40 --$(DEVICE) --package $(PACKAGE) \
	   --json $(JSON) --pcf $(PCF) --asc $@ \
	   --report $(BUILD_DIR)/nextpnr.report.json \
	   --log $(BUILD_DIR)/nextpnr.log

$(BIN): $(ASC)
	icepack $< $@

$(TIMING): $(ASC)
	icetime -d $(DEVICE) -mtr $@ $<

prog: $(BIN)
	iceprog $<

clean:
	rm -rf $(BUILD_DIR)
