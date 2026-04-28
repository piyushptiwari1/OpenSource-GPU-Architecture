# Formal verification (SymbiYosys + yices2)

Bounded model checking (BMC) with **SymbiYosys** driving **yosys** + **yices2**
(both via OSS CAD Suite). Each `formal/<module>/` directory is self-contained:

| File                  | Role                                                                 |
| --------------------- | -------------------------------------------------------------------- |
| `<m>.sby`             | SymbiYosys recipe (engines, depth, files).                           |
| `<m>_props.sv`        | Property module: pure observer with immediate `assert` statements.   |
| `<m>_formal_top.sv`   | Wraps DUT + props as a single top so sby has one root to elaborate.  |

## Why immediate asserts (not concurrent SVA)

The default yosys formal frontend does not accept module-scope
`assert property (...)` blocks or `default clocking` syntax. We use the
common workaround: a clock-synchronous `always @(posedge clk)` block
with plain `assert (...)` calls, plus manually-tracked one-cycle history
flops (`past_*`). This compiles cleanly and runs against `smtbmc yices`.

## Currently proven

- `formal/dcr/`: 3 properties (reset clears, write strobe latches,
  no-write hold) over `src/dcr.sv`. BMC depth 20, runtime <1s.

## Next-up (intentionally not yet wired in)

Modules whose properties need either intrusive RTL changes or the
`bind` directive to access internal state:

- `pc.sv`     — branch-decision proofs need access to internal NZP
  register; requires an exported probe port or bind-based binding.
- `fetcher.sv`, `dispatch.sv`, `scheduler.sv` — handshake invariants
  (no-double-issue, no-missing-ack); planned for the next formal
  increment along with assume/cover lemmas.

## Running locally

```bash
docker run --rm -v "$PWD:/work" -w /work \
    ghcr.io/piyushptiwari1/opengpu-toolchain:latest \
    bash -lc "cd formal/dcr && sby -f dcr.sby"
```

CI runs the full set on every push touching `src/**` or `formal/**`;
see `.github/workflows/formal.yml`.
