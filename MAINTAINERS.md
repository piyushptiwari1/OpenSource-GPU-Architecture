# Maintainers

| Role            | Handle           | Areas                                  |
|-----------------|------------------|----------------------------------------|
| Lead maintainer | @piyushptiwari1  | All; final approver                    |
| Original author | @adam-maj        | Upstream tiny-gpu (advisory)           |

## Adding a maintainer

A new maintainer is added by consensus of existing maintainers after
consistent, high-quality contributions across at least two of:

- RTL (`src/`)
- Verification (`test/`, `formal/`, `sim/cppref/`)
- Open ASIC / FPGA flows (`flow/`)
- Toolchain (`tools/`, `.github/workflows/`)
- Documentation (`docs/`)

A pull request adding the new maintainer to this file plus updates to
`.github/CODEOWNERS` formalizes the change.

## Decision process

- Routine: maintainer approval on PR is sufficient.
- Architectural changes (ISA, microarchitecture, toolchain swaps):
  documented in an issue with the `rfc` label, open at least 7 days,
  resolved by lazy consensus.
- Disputes: lead maintainer breaks ties.
