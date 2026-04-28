# Commercial / proprietary EDA flow

This directory contains build targets that invoke licensed EDA tools
(Synopsys DC/ICC2/PrimeTime, Cadence Genus/Innovus, Xilinx Vivado,
Intel Quartus Prime Pro). Public CI runs only the **open** flow
(OpenLane2 + sky130, Yosys+nextpnr); commercial targets are gated on
`OPENGPU_COMMERCIAL=1` plus the vendor license environment variables.

## Activation

```bash
export OPENGPU_COMMERCIAL=1
export SNPS_LM_LICENSE_FILE=27000@<your-license-server>
export CDS_LIC_FILE=5280@<your-license-server>
export XILINX_LICENSE=<...>     # for Vivado paid features
make -C flow/commercial asic_synth
```

Without `OPENGPU_COMMERCIAL=1`, every gated target exits with a clear
error — by design, so contributors without licenses cannot accidentally
trigger a commercial run.

## Targets

| Target                  | Tool                            |
|-------------------------|---------------------------------|
| `asic_lint`             | Verilator (open, no license)    |
| `asic_synth`            | Synopsys DC / Cadence Genus     |
| `asic_pnr`              | Synopsys ICC2 / Cadence Innovus |
| `asic_signoff`          | Synopsys PrimeTime + StarRC     |
| `asic_gds`              | ICC2 / Innovus stream-out       |
| `fpga_xilinx`           | Xilinx Vivado                   |
| `fpga_xilinx_program`   | Xilinx Vivado                   |
| `fpga_intel`            | Intel Quartus Prime Pro         |
| `fpga_intel_program`    | Intel Quartus Prime Pro         |

## CI policy

`commercial.yml` runs `make -n` (dry-run) on every push to validate
Makefile syntax. It is **never** invoked with real licenses in public
CI; that is reserved for self-hosted runners owned by users with
appropriate license entitlements.

## See also

- Open ASIC flow: `flow/openlane2/` (sky130A, no license required).
- Open FPGA flows: `flow/fpga/` (Yosys + nextpnr).
- Architectural rationale: §C-10 of `docs/integration-plan.md`.
