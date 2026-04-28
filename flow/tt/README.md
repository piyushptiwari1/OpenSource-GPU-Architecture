# Tiny Tapeout submission

This directory holds the **Tiny Tapeout** track for OpenGPU
(C-20 Path A in the integration plan). The chip wrapper is the
standard `tt_um_*` adapter that bridges the 8-bit ui_in / uo_out /
uio pinout to the GPU's host interface.

## Layout

| File                              | Purpose                                                                 |
|-----------------------------------|-------------------------------------------------------------------------|
| `../../src/tt_um_tiny_gpu.sv`     | Top-level wrapper exposed to the Tiny Tapeout harness.                  |
| `../../src/info.yaml`             | TT project manifest (loaded by `tt-support-tools`).                     |
| `flow/tt/config.json`             | OpenLane2 hardening config (sky130A, multi-tile, 10 MHz clock).         |
| `flow/tt/docs/info.md`            | Public description rendered on the Tiny Tapeout site.                   |
| `.github/workflows/tt.yml`        | CI: synth-check on every push; full GDS via workflow_dispatch.          |

## Build (local)

Requires OpenLane2 and the sky130A PDK installed. The toolchain image
`ghcr.io/piyushptiwari1/opengpu-toolchain:latest` ships a pinned
OpenLane2 client.

```bash
cd flow/tt
openlane --run-tag tt-local config.json
ls runs/tt-local/final/gds/   # streamed-out GDSII
```

## Submission

Tiny Tapeout windows accept submissions via their fork of this repo
into `tinytapeout/tt-submissions`. The TT CI builds the GDS from
`src/info.yaml` automatically; nothing else is needed on our side.

Key invariants the TT tooling enforces and we must keep stable:

- The top must be named `tt_um_<slug>` and live under `src/`.
- `src/info.yaml` must list every file consumed by the wrapper.
- The wrapper signature is fixed: `(ui_in, uo_out, uio_in, uio_out, uio_oe, ena, clk, rst_n)`.

## Tile budget

The first harden run reports `Core utilisation = X %` in
`runs/<tag>/final/metrics.csv`. If utilisation exceeds ~90 %, raise
the `tiles:` value in `src/info.yaml` and re-harden. The current
budget of `4x2` tiles (~640 × 200 µm) is a starting estimate — the
full `gpu` core has historically fitted in this envelope when
SYNTH_STRATEGY = "AREA 0".

## See also

- Open ASIC (full chip, larger): `flow/openlane2/`
- Open FPGA flows: `flow/fpga/`
- Caravel / Open MPW (full SoC, separate path): planned under
  `flow/caravel/` (C-20 Path B).
