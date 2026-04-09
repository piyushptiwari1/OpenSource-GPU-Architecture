# tiny-gpu

A minimal, educational GPU implementation in SystemVerilog with Python-based simulation tests.

## Project Overview

This project implements a simple GPU architecture capable of executing kernels written in a custom 11-instruction assembly ISA. It is designed for learning GPU architecture concepts including SIMD execution, thread dispatching, and memory controllers.

## Tech Stack

- **Hardware Description Language:** SystemVerilog (`.sv` files in `src/`)
- **Simulation Framework:** Cocotb 2.x (Python coroutine-based verification)
- **Verilog Compiler:** Icarus Verilog (`iverilog`)
- **SV to Verilog Converter:** `sv2v` (downloaded binary at `/home/runner/.local/bin/sv2v`)
- **Python Version:** 3.12 (managed via Replit/uv in `.pythonlibs/`)

## Project Structure

```
src/           - SystemVerilog source files (GPU components)
test/          - Cocotb Python test suite
  helpers/     - Shared utilities (memory, logging, formatting)
  test_matadd.py  - Matrix addition kernel test
  test_matmul.py  - Matrix multiplication kernel test
build/         - Compiled output (generated, gitignored)
docs/          - Architecture diagrams
gds/           - Physical layout files
Makefile       - Build and simulation orchestration
```

## Running Simulations

The "Run Simulation" workflow runs both GPU simulations (matrix addition and multiplication).

To run manually:
```bash
export PATH="/home/runner/.local/bin:/home/runner/workspace/.pythonlibs/bin:$PATH"
make test_matadd   # Run matrix addition test
make test_matmul   # Run matrix multiplication test
```

## Environment Setup Notes

### Tools Installed
- `iverilog` (Icarus Verilog 12.0) - installed via Nix system packages
- `sv2v` v0.0.13 - downloaded binary placed at `/home/runner/.local/bin/sv2v`
- `cocotb` 2.0.1 - installed via pip into `.pythonlibs/`

### Makefile Changes from Original
The original Makefile used cocotb 1.x syntax. Updated for cocotb 2.x:
- `--prefix` flag → replaced with `--lib-dir`
- `MODULE=` env var → replaced with `COCOTB_TEST_MODULES=`
- Added `PYGPI_PYTHON_BIN` and `LD_LIBRARY_PATH` for proper Python embedding

### test/helpers/format.py Changes
Fixed `LogicArray` type compatibility for cocotb 2.x:
- `core.i.value * dut.THREADS_PER_BLOCK.value` → wrapped in `int()`
- `int(core.core_instance.THREADS_PER_BLOCK)` → `int(core.core_instance.THREADS_PER_BLOCK.value)`
- `block_idx` and `thread_idx` explicitly cast to `int`

### test/helpers/setup.py Changes
- `Clock(dut.clk, 25, units="us")` → `Clock(dut.clk, 25, unit="us")` (cocotb 2.x API)
