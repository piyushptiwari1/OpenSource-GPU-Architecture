# OpenGPU physical-implementation flows

Three reproducible flows hardened around the same RTL
(`src/*.sv` — original tiny-gpu set; the enterprise SoC tree under
`src/*` is intentionally excluded until its sv2v collisions are
cleaned up):

| Flow | Tools | Target | Status |
|------|-------|--------|--------|
| [`synth/`](synth/) | yosys (generic) | synthesizability check | CI-gated |
| [`fpga/ice40/`](fpga/ice40/) | yosys + nextpnr-ice40 + icepack | iCE40HX8K-CT256 | manual / dispatch |
| [`fpga/ecp5/`](fpga/ecp5/)   | yosys + nextpnr-ecp5 + ecppack | ECP5-25F (ULX3S) | manual / dispatch |
| [`openlane2/`](openlane2/)   | OpenLane2 (`librelane`) | sky130A ASIC | manual / dispatch |

All flows pull SystemVerilog from `src/` and the FPGA flows wrap it
with [`flow/fpga/common/gpu_fpga_top.sv`](fpga/common/gpu_fpga_top.sv),
which embeds program / data BRAM, a reset synchroniser, and a button
debouncer.

Bitstream programs are loaded from `flow/fpga/programs/*.hex` (small
hand-assembled kernels matching `docs/isa/instructions.yaml`). Until
the assembler driver lands (Step 8), use `tools/asm/opengpu.asm` with
`customasm` to produce new ones.

## CI

`.github/workflows/flow.yml` runs the synthesizability check on every
push/PR. It also exposes `workflow_dispatch` jobs to run a full
nextpnr place-and-route on iCE40 and ECP5 boards (handy for tracking
LUT/FF/BRAM utilisation drift). OpenLane2 is **not** in CI yet — it
needs ~30 min and a separately fetched PDK; run it locally per the
[`openlane2/README.md`](openlane2/README.md).
