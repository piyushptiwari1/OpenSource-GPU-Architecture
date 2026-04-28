# OpenGPU

A minimal, fully open-source 16-bit SIMT GPU implemented in SystemVerilog,
with a complete CI toolchain, a C++ reference simulator, an executable
ISA spec, and a DiffTest harness.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/blob/main/LICENSE)
[![Lint](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/actions/workflows/lint.yml/badge.svg)](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/actions/workflows/lint.yml)
[![Sim](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/actions/workflows/sim.yml/badge.svg)](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/actions/workflows/sim.yml)
[![Refsim](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/actions/workflows/refsim.yml/badge.svg)](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/actions/workflows/refsim.yml)

## Why

Most GPU architectures are proprietary. The few open implementations
([Miaow](https://github.com/VerticalResearchGroup/miaow),
[VeriGPU](https://github.com/hughperkins/VeriGPU)) target full
feature-parity, which makes them hard to study. **OpenGPU** is the
opposite end of the spectrum: small enough to read end-to-end,
disciplined enough to ship.

## What you get

| Artefact | Where | Status |
|----------|-------|:------:|
| 16-bit SIMT RTL | [`src/`](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/tree/main/src) | ✓ |
| Canonical ISA YAML | [`docs/isa/instructions.yaml`](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/blob/main/docs/isa/instructions.yaml) | ✓ |
| Auto-generated assembler grammar + C++ decode table | [`tools/codegen/`](tooling/codegen.md) | ✓ |
| C++ reference simulator (`opengpu-refsim`) | [`sim/cppref/`](refsim/index.md) | ✓ |
| DiffTest harness (RTL ↔ refsim, JSONL retire stream) | [`tools/difftest/`](tooling/difftest.md) | ✓ |
| Pinned EDA toolchain image | `ghcr.io/piyushptiwari1/opengpu-toolchain` | ✓ |
| Cocotb module + e2e tests | [`test/`](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/tree/main/test) | ✓ |

## Where to start

- New here? Read the [Architecture overview](report/02-architecture-and-execution.md).
- Want the instruction set? See the [ISA reference](isa/reference.md)
  (auto-rendered from YAML).
- Hacking on RTL? Start with the [Build & test workflow](report/03-build-and-test-workflow.md)
  and the [cocotb overview](cocotb-overview.md).
- Tracing a kernel run? The [matadd walkthrough](report/05-matadd-trace-walkthrough.md)
  steps through retired instructions one at a time.

## Project layout

```
.
├── src/                    SystemVerilog RTL
├── test/                   Cocotb test benches (per module + e2e kernels)
├── sim/cppref/             C++ reference simulator (CMake + Catch2)
├── tools/codegen/          ISA YAML → C++ table + asm grammar + this site
├── tools/difftest/         JSONL stream comparator (RTL ↔ refsim)
├── containers/toolchain/   Pinned OSS HDL/EDA image
├── docs/                   This site (mkdocs-material)
└── .github/workflows/      Lint, Sim, Refsim, Docs, Build-toolchain
```

## License

MIT — see [`LICENSE`](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/blob/main/LICENSE).
