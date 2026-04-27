<!-- Thanks for contributing! Please fill in the sections below. -->

## Summary

<!-- One paragraph describing what this PR changes and why. -->

## Type of change

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (RTL/ISA/build interface change requiring callers to adapt)
- [ ] Documentation only
- [ ] CI / tooling only

## Affected areas

- [ ] `src/` (RTL)
- [ ] `test/` / `sim/` / `formal/` (verification)
- [ ] `flow/openlane2/` or `flow/fpga/*` (back-end flows)
- [ ] `tools/` / `.github/workflows/` (toolchain / CI)
- [ ] `docs/` (documentation)

## Verification performed

<!-- Tick all that apply and paste the relevant command + final status line. -->

- [ ] `make lint` passes
- [ ] `make tests` passes locally (paste summary)
- [ ] Added or updated cocotb tests for the changed module
- [ ] Added or updated formal properties (`formal/<module>/`)
- [ ] Re-ran `make synth-fpga BOARD=<name>` for affected RTL
- [ ] Re-ran OpenLane2 sanity flow for affected RTL

## Checklist

- [ ] My commits are signed off (`git commit -s`)
- [ ] I updated `CHANGES.md`
- [ ] I updated relevant docs under `docs/`
- [ ] No vendor-encumbered files added
- [ ] No secrets, license keys, or `.env` content committed
