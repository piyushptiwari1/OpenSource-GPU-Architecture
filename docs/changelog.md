# Changelog

The authoritative changelog is
[`CHANGES.md`](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/blob/main/CHANGES.md)
in the repo root, which maps every merged upstream PR and resolved
issue to the file changes that integrated it.

This page summarises milestones at a higher level.

## Unreleased

- Step 5 — Documentation site (mkdocs-material) live on GitHub Pages,
  with auto-rendered ISA reference and `mkdocstrings` API docs for the
  Python tooling.
- Step 4 — Canonical ISA YAML, C++ reference simulator (`opengpu-refsim`),
  DiffTest harness comparing RTL ↔ refsim retire streams.
- Step 3 — Simulation CI rebuilt around the pinned toolchain image; 8/8
  module tests green on every push.
- Step 2 — Reproducible toolchain Docker image
  (`ghcr.io/piyushptiwari1/opengpu-toolchain`) and matching dev container.
- Step 1 — Repository governance, ruff + mypy + Verible + pyslang lint
  gates, CODEOWNERS, contribution docs.
