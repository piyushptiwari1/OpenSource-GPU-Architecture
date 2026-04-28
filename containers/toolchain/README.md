# OpenGPU toolchain image

Reproducible OSS HDL/EDA toolchain consumed by CI workflows and the
VS Code Dev Container. Built from [`Dockerfile`](Dockerfile); versions
sourced from [`tools/versions.env`](../../tools/versions.env).

## Contents

| Tool         | Source                                        |
|--------------|-----------------------------------------------|
| Yosys        | OSS CAD Suite                                 |
| Verilator    | OSS CAD Suite                                 |
| Icarus iverilog | OSS CAD Suite                              |
| nextpnr (ecp5/ice40/nexus) | OSS CAD Suite                   |
| GHDL, gtkwave, cocotb runtime | OSS CAD Suite              |
| Verible      | chipsalliance/verible release                 |
| pyslang      | pip                                           |
| ruff, mypy   | pip                                           |
| pytest, cocotb (Python) | pip                                |

## Local build

```bash
set -a && . tools/versions.env && set +a
docker build \
  --build-arg OSS_CAD_SUITE_DATE \
  --build-arg OSS_CAD_SUITE_ARCH \
  --build-arg OSS_CAD_SUITE_SHA256 \
  --build-arg VERIBLE_VERSION \
  --build-arg PYTHON_VERSION \
  -t opengpu-toolchain:dev \
  -f containers/toolchain/Dockerfile .
```

## CI

Built and pushed to `ghcr.io/piyushptiwari1/opengpu-toolchain` by
[`.github/workflows/build-toolchain.yml`](../../.github/workflows/build-toolchain.yml)
on changes to `containers/**` or `tools/versions.env`, on a weekly
schedule, and via manual dispatch. Tags:

- `latest`    — most recent successful build on `main`
- `<git-sha>` — exact commit
- `YYYYMMDD`  — date stamp on scheduled rebuilds
