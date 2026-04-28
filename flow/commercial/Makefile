# Commercial ASIC / proprietary-FPGA flow (C-10).
#
# Targets in this file invoke commercial EDA tools (Synopsys
# DC/ICC2/PrimeTime, Cadence Genus/Innovus, Xilinx Vivado, Intel
# Quartus). They are intentionally NOT exercised in the public CI;
# license servers are only available on self-hosted runners.
#
# Public CI may run `make -n` here to validate Makefile syntax via
# the gated job in `.github/workflows/commercial.yml`.
#
# Activate by setting `OPENGPU_COMMERCIAL=1` in the environment plus
# the appropriate vendor license variables:
#   SNPS_LM_LICENSE_FILE  - Synopsys (DC/ICC2/PT/VCS)
#   CDS_LIC_FILE          - Cadence (Genus/Innovus)
#   XILINX_LICENSE        - Vivado paid features
#   MENTOR_LICENSE_FILE   - Mentor/Siemens (Questa, optional)

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)

.PHONY: help guard \
        asic_lint asic_synth asic_pnr asic_signoff asic_gds \
        fpga_xilinx fpga_xilinx_program fpga_intel fpga_intel_program

help:
	@echo "Commercial flow targets (require vendor licenses)"
	@echo "================================================="
	@echo "  make asic_lint           - Verilator lint (no license needed)"
	@echo "  make asic_synth          - Synopsys DC / Cadence Genus"
	@echo "  make asic_pnr            - Synopsys ICC2 / Cadence Innovus"
	@echo "  make asic_signoff        - Synopsys PrimeTime + StarRC"
	@echo "  make asic_gds            - Stream out from ICC2/Innovus"
	@echo "  make fpga_xilinx         - Xilinx Vivado build"
	@echo "  make fpga_xilinx_program - Program Xilinx FPGA"
	@echo "  make fpga_intel          - Intel Quartus Prime Pro build"
	@echo "  make fpga_intel_program  - Program Intel FPGA"
	@echo ""
	@echo "Set OPENGPU_COMMERCIAL=1 plus vendor license vars to enable."

# All commercial targets gate on this guard: refuse to run unless
# the user has explicitly opted in with OPENGPU_COMMERCIAL=1.
guard:
	@if [ "$$OPENGPU_COMMERCIAL" != "1" ]; then \
	  echo "ERROR: commercial flow not enabled."; \
	  echo "       Set OPENGPU_COMMERCIAL=1 plus vendor license vars."; \
	  exit 1; \
	fi

################################################################################
# ASIC
################################################################################

# Lint with Verilator (open) — kept here for parity but does not need
# OPENGPU_COMMERCIAL since Verilator is permissively-licensed.
asic_lint:
	@echo "Running lint checks..."
	cd $(REPO_ROOT) && verilator --lint-only -Wall -Wno-fatal src/gpu_soc.sv src/*.sv

asic_synth: guard
	@echo "Running ASIC synthesis (Synopsys DC or Cadence Genus)..."
	@if [ -f $(REPO_ROOT)/vlsi/scripts/synthesis.tcl ]; then \
	  echo "Found vlsi/scripts/synthesis.tcl"; \
	  echo "Run: dc_shell -f vlsi/scripts/synthesis.tcl"; \
	else \
	  echo "Create synthesis script at vlsi/scripts/synthesis.tcl"; \
	  exit 2; \
	fi

asic_pnr: guard
	@echo "Running ASIC place and route (Synopsys ICC2 or Cadence Innovus)..."
	@echo "Run: icc2_shell -f vlsi/scripts/pnr.tcl"

asic_signoff: guard
	@echo "Running signoff checks (Synopsys PrimeTime + StarRC)..."
	@echo "Run: pt_shell -f vlsi/scripts/signoff.tcl"

asic_gds: guard
	@echo "Streaming out GDSII..."
	@echo "Run: streamout from ICC2/Innovus"

################################################################################
# Proprietary FPGA flows
################################################################################

fpga_xilinx: guard
	@echo "Building for Xilinx FPGA (Ultrascale+)..."
	@if command -v vivado >/dev/null 2>&1; then \
	  vivado -mode batch -source $(REPO_ROOT)/fpga/xilinx/scripts/build.tcl; \
	else \
	  echo "Vivado not found. Install Xilinx Vivado 2023.x"; \
	  exit 2; \
	fi

fpga_xilinx_program: guard
	@echo "Programming Xilinx FPGA..."
	@if command -v vivado >/dev/null 2>&1; then \
	  vivado -mode batch -source $(REPO_ROOT)/fpga/xilinx/scripts/program.tcl; \
	else \
	  echo "Vivado not found"; \
	  exit 2; \
	fi

fpga_intel: guard
	@echo "Building for Intel FPGA (Agilex / Stratix 10)..."
	@if command -v quartus_sh >/dev/null 2>&1; then \
	  quartus_sh --flow compile $(REPO_ROOT)/fpga/intel/gpu_project; \
	else \
	  echo "Quartus not found. Install Intel Quartus Prime Pro 23.x"; \
	  exit 2; \
	fi

fpga_intel_program: guard
	@echo "Programming Intel FPGA..."
	@if command -v quartus_pgm >/dev/null 2>&1; then \
	  quartus_pgm -c 1 -m jtag -o "p;$(REPO_ROOT)/fpga/intel/output_files/gpu_soc.sof"; \
	else \
	  echo "Quartus not found"; \
	  exit 2; \
	fi
