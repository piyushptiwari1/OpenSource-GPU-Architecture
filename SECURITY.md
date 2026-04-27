# Security Policy

## Supported versions

The `main` branch receives security fixes. Tagged releases on the
`v0.x` line receive critical fixes for 90 days after the next minor
release. Older tags are best-effort.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Use one of:

1. **GitHub private vulnerability reporting** — preferred. Go to
   <https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/security/advisories/new>.
2. **Email** — open an issue titled "security contact request" without
   technical details, and a maintainer will respond with a private
   address.

Please include:

- A description of the issue.
- Steps to reproduce or a proof-of-concept.
- Affected commit hash or release tag.
- Your assessment of impact.

## Response

- We acknowledge reports within 5 business days.
- A fix is targeted within 30 days for high-severity issues.
- We coordinate disclosure with the reporter and credit them in the
  release notes (unless they prefer anonymity).

## Scope

In scope:

- RTL / SystemVerilog modules under `src/`.
- Python tooling under `tools/` and `test/`.
- CI pipelines under `.github/workflows/` (e.g. secret leakage,
  dependency confusion, malicious script injection).
- Generated artifacts published to GitHub Releases / GHCR / PyPI.

Out of scope:

- Vulnerabilities in upstream dependencies (Yosys, OpenLane, cocotb,
  Verilator, etc.). Report those upstream; we will pull fixes once
  released.
- Issues that require a malicious PDK, compromised toolchain image, or
  physical access to the device.
- Findings against the `Makefile.vlsi` commercial flow (not part of
  the supported open path).
