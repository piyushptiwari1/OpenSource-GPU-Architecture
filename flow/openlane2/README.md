# OpenLane2 sky130 ASIC flow

Hardens the tiny-gpu top (`src/gpu.sv` + dependencies) for the
SkyWater 130 nm open PDK using the OpenLane2 / `librelane` Classic
flow.

## Run locally

```bash
# 1) Install librelane (Python package, fetches sky130A PDK lazily).
pip install librelane

# 2) Run from this directory.
cd flow/openlane2
librelane config.json --run-tag main
```

The first run downloads sky130A (~1 GB) into `~/.volare/`; subsequent
runs reuse it. The full flow takes 20–40 minutes on a modern laptop
and produces:

- `runs/main/final/gds/gpu.gds` — final GDS layout
- `runs/main/final/lef/gpu.lef` — abstract LEF
- `runs/main/final/spef/*` — parasitics for sign-off STA
- `runs/main/reports/` — synthesis, place, route, STA, DRC, LVS

## CI

OpenLane2 is **not** in the always-on CI matrix because it pulls a
1 GB PDK and takes 30 min. To run it on demand, dispatch the
`flow.yml` workflow with `flow=openlane2` (planned). Until then,
contributors run it locally and attach the `runs/main/final/`
artefacts to a PR description.

## What `config.json` does

| Knob | Value | Why |
|------|-------|-----|
| `DESIGN_NAME` | `gpu` | matches `src/gpu.sv` top |
| `CLOCK_PERIOD` | `50.0` ns | conservative 20 MHz target on sky130 hd |
| `STD_CELL_LIBRARY` | `sky130_fd_sc_hd` | stable open PDK pick |
| `DIE_AREA` | `0 0 600 600` | tiny-gpu fits comfortably; revisit when shrinking |
| `FP_CORE_UTIL` | `35` | low utilisation while we're still debugging tristate inference |
| `SYNTH_STRATEGY` | `AREA 0` | minimum area; switch to `DELAY 0` once timing closure starts |
| `RUN_LINTER` | `true` | catches common synth issues early |
| `USE_SYNLIG` | `false` | use the OpenLane2-bundled sv2v path; avoids Synlig dependency |

## Related

- Full flow guide: <https://openlane2.readthedocs.io/>
- PDK reference:  <https://skywater-pdk.readthedocs.io/>
- librelane:      <https://github.com/librelane/librelane>
