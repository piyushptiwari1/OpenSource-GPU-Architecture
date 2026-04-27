# Contributing to OpenSource-GPU-Architecture

Thank you for your interest in contributing! This project is a
production-oriented continuation of [adam-maj/tiny-gpu], with merged
upstream PRs, expanded verification, and a fully open EDA flow.

[adam-maj/tiny-gpu]: https://github.com/adam-maj/tiny-gpu

## Ground rules

1. By submitting a contribution you agree to license it under the
   project's [MIT License](LICENSE) and to follow the
   [Code of Conduct](CODE_OF_CONDUCT.md).
2. All commits must be **signed off** under the
   [Developer Certificate of Origin (DCO)](https://developercertificate.org).
   Use `git commit -s` (adds `Signed-off-by: Name <email>`).
3. Keep changes focused. One logical change per PR.
4. Do not include vendor-encumbered files (Synopsys/Cadence/Mentor
   outputs, proprietary PDK views, etc.) under `src/`, `flow/openlane2/`
   or any open-flow directory.

## Repository layout

```
src/                   SystemVerilog RTL (single source of truth)
test/                  cocotb v2 testbenches
sim/                   Simulator drivers
  iverilog/            Default iverilog flow
  verilator/           Verilator flow (faster)
  cppref/              C++20 reference ISA simulator (DiffTest golden)
  memory/              DRAM model wrappers (Ramulator2 / DRAMSim3)
flow/
  openlane2/           Open ASIC flow (Yosys + OpenROAD + sky130A)
  fpga/<board>/        Per-board open FPGA flows (nextpnr, etc.)
  commercial/          Reference for proprietary tools (not run in CI)
formal/                SymbiYosys formal proofs
tools/
  asm/                 customasm grammar (generated from ISA YAML)
  codegen/             ISA YAML → asm grammar / cppref tables / docs
  lint/                Verible rules
docs/                  MkDocs Material site
  isa/instructions.yaml   Canonical machine-readable ISA spec
bench/                 Benchmark kernels + dashboards
.github/workflows/     CI definitions (one job per concern)
```

The ISA YAML (`docs/isa/instructions.yaml`) is the **single source of
truth**. The assembler grammar, C++ reference decoder, and
documentation are all generated from it. Hand-editing the generated
files will be reverted.

## Local development

```bash
git clone git@github.com:piyushptiwari1/OpenSource-GPU-Architecture.git
cd OpenSource-GPU-Architecture

# Copy environment template
cp .env.example .env

# (Recommended) Use the dev container — see .devcontainer/.
# Or install the OSS CAD Suite locally:
#   https://github.com/YosysHQ/oss-cad-suite-build/releases

# Python deps for cocotb + tooling
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

# Run a single test
make test_matadd

# Run all tests
make tests
```

## Coding standards

### SystemVerilog
- `\`default_nettype none` at the top of every module.
- Lower snake_case for signals, UpperCamelCase for parameters and
  typedef names, ALL_CAPS for compile-time constants.
- Use `unique case` with a `default` arm; never bare `case`.
- Avoid implicit truncation — size all literals.
- Reset all storage to a known state. Per-element loops where required
  by tools (Quartus dislikes `'{default:0}` on unpacked arrays — see
  PR-22/25 fix).
- Every PR runs `make lint` (verible-verilog-lint + slang).

### Python
- Format: `ruff format` (Black-compatible).
- Lint: `ruff check` with rules in `pyproject.toml`.
- Types: prefer type hints; `mypy --strict` on `tools/`.
- Tests: `pytest`. New modules ship with tests.

## Pull request process

1. Fork → branch off `main` → name as `feature/<topic>` or `fix/<topic>`.
2. Run locally: `make lint && make tests`.
3. Update `CHANGES.md` under the appropriate heading.
4. Open the PR; CI must be green before review.
5. At least one maintainer approval is required to merge.
6. Squash-merge is the default. Commits in `main` are atomic.

## Reporting bugs / requesting features

Use the templates in `.github/ISSUE_TEMPLATE/`. Include:

- Repro steps, expected vs actual behavior.
- Toolchain versions: `iverilog -V`, `verilator --version`,
  `python --version`, `cocotb` version.
- Minimal failing test (`test/cocotb/<feature>/test_*.py`).

## Security issues

See [SECURITY.md](SECURITY.md) for private disclosure.

## License

MIT. Contributions are accepted under the same terms.
