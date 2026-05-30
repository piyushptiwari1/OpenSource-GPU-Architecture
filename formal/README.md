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

## SystemVerilog frontend: built-in vs `slang`

`dcr` uses scalar ports, so the built-in `read -formal -sv` frontend parses
it directly. Modules with **unpacked-array ports** (e.g. `scheduler.sv`'s
`lsu_state [N-1:0]` / `next_pc [N-1:0]`) are not accepted by the built-in
frontend, so those recipes load the **`slang`** plugin (`plugin -i slang;
read_slang ...`) — a full SystemVerilog frontend shipped in OSS CAD Suite that
handles unpacked arrays and immediate assertions natively. `slang` requires a
consistent `` `timescale `` across all files in the elaboration.

## Currently proven

- `formal/dcr/`: 3 properties (reset clears, write strobe latches,
  no-write hold) over `src/dcr.sv`. BMC depth 20, runtime <1s.
- `formal/scheduler/`: 6 safety invariants over the `scheduler.sv` core FSM
  — `reset_state`, `legal_transition` (every state advances only along a legal
  FSM edge), `start_gate` (IDLE left only on `start`), `done_implies_done_state`,
  `done_sticky`, and `active_subset` (every active lane is a valid lane). Proven
  by **k-induction** (`mode prove`, depth 20) via the `slang` frontend, so the
  guarantee is unbounded (not merely bounded). Runtime ~2s.
- `formal/fetcher/`: 5 handshake invariants over the `fetcher.sv` read FSM —
  `reset_state`, `legal_transition`, `valid_iff_fetching` (the read request is
  asserted exactly in FETCHING), `addr_stable` (address + valid held while a
  request is outstanding), and `ack_clears_valid` (no double-issue after ack).
  Proven by **k-induction** (`mode prove`, depth 20). Runtime <1s.
- `formal/dispatch/`: 3 port-observable invariants over `dispatch.sv` —
  `reset_state`, `start_reset_mutex` (a core is never started and reset at
  once), and `done_sticky` (monotonic completion). Proven by **BMC** (`mode
  bmc`, depth 30) via the `slang` frontend. BMC rather than k-induction because
  the EDA `start_execution` hack makes `start_reset_mutex` true for every
  reachable state but not 1-step inductive; proving it by induction would need
  to probe the internal `start_execution` register (bind / RTL change), which
  we defer. Runtime ~1s.

## Next-up (intentionally not yet wired in)

Modules whose properties need either intrusive RTL changes or the
`bind` directive to access internal state:

- `pc.sv`     — branch-decision proofs need access to internal NZP
  register; requires an exported probe port or bind-based binding.
- `lsu.sv`    — load/store handshake invariants analogous to the fetcher;
  next natural increment.

## Running locally

From the repository root, the quickest smoke run is:

```bash
make formal_smoke
```

Equivalent direct invocation (same proof target) is:

```bash
docker run --rm -v "$PWD:/work" -w /work \
    ghcr.io/piyushptiwari1/opengpu-toolchain:latest \
    bash -lc "cd formal/dcr && sby -f dcr.sby"
```

CI runs the full set on every push touching `src/**` or `formal/**`;
see `.github/workflows/formal.yml`.
