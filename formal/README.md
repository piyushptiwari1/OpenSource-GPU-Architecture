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
- `formal/lsu/`: 5 handshake invariants over the `lsu.sv` 4-state load/store FSM
  — `reset_state`, `legal_transition` (incl. the atomic `WAITING->REQUESTING`
  write re-issue), `valid_mutex` (at most one of the four global/shared
  read/write request lines asserted at once), `addr_stable` (address + data +
  valid held while a global request is outstanding), and `ack_clears_valid`
  (no double-issue after ack). Uses an **assume-guarantee** env contract: the
  upstream holds the decoded instruction + `enable` stable while a transaction
  is in flight (`lsu_state != IDLE`), exactly the master-holds-request-stable
  assumption used in AXI/valid-ready proofs. Proven by **BMC** (`mode bmc`,
  depth 30) — the unconstrained internal `atomic_phase` flag makes the
  invariants reachable-true but not 1-step inductive. Runtime ~9s.
- `formal/pc/`: 7 branch-decision invariants over `pc.sv` — `reset_state`,
  `seq_update` (non-branch advances `pc+1`), `branch_taken` (a BRnzp whose NZP
  mask matches the latched flags jumps to the decoded immediate), `branch_
  nottaken` (non-matching BRnzp falls through to `pc+1`), `nzp_latch` (a CMP in
  UPDATE captures `alu_out[2:0]`), `nzp_hold` (NZP only changes on a CMP step),
  and `pc_hold` (`next_pc` only changes on an EXECUTE step). **White-box**: the
  formal top reads the internal `nzp` register through a hierarchical reference
  (`u_pc.nzp`) so the exact branch *target* is proven, not merely that `next_pc`
  is one of two values — no `bind` and no RTL change. Requires the `slang`
  frontend (the built-in frontend rejects hierarchical references under
  `` `default_nettype none ``). Proven by **k-induction** (`mode prove`, depth
  20), so the guarantee is unbounded. Runtime <1s.
- `formal/core/`: 6 **cross-module** sequencing invariants over the fully
  elaborated `core.sv` (the integration / "capstone" proof) — `fetch_valid_
  gated` (program memory driven only while the fetcher is FETCHING),
  `fetch_starts_in_fetch` (fetcher leaves IDLE only when the scheduler reached
  FETCH — the request edge), `decode_after_fetched` (scheduler advances
  FETCH→DECODE only once the fetcher reports FETCHED — the acknowledge edge),
  `fetcher_clears_on_decode` (fetcher retires FETCHED→IDLE only in DECODE — the
  teardown), `mem_request_gated` (a lane's LSU drives the data-memory request
  lines only in REQUEST/WAIT), and `done_in_done_state`. Whereas the per-module
  proofs above each verify one FSM in isolation under an assume-guarantee
  contract, this suite proves those independently-verified FSMs *compose*
  correctly once wired together, with **no environment assumptions** (every core
  input is free symbolic stimulus). **White-box**: the scheduler's and fetcher's
  state registers are observed through hierarchical references
  (`u_core.core_state`, `u_core.fetcher_state`) — no `bind`, no RTL change.
  Uses **datapath abstraction** (`blackbox alu registers shared_memory`): the
  control handshakes do not depend on computed data, so the pure-datapath
  modules are cut to free symbolic outputs (a sound over-approximation for
  safety), keeping the multi-module BMC tractable while every control FSM stays
  fully modelled. Proven by **BMC** (`mode bmc`, depth 14) via the `slang`
  frontend. Runtime ~1 min.
- `formal/alu/`: 7 result-correctness invariants over `alu.sv` — `reset_state`,
  `cmp_result` (output_mux==1 yields the NZP compare word `{5'b0, rs<rt, rs==rt,
  rs>rt}`), `add_result` / `sub_result` / `mul_result` / `div_result` (each
  arithmetic opcode matches its spec; DIV guarded `rt != 0`, division by zero
  left unconstrained exactly as the RTL leaves it), and `out_hold` (the result
  register only changes on an enabled EXECUTE step). A self-checking reference-
  model proof: the registered `alu_out` is compared against the spec recomputed
  from the previous cycle's operands. Proven by **k-induction** (`mode prove`,
  depth 10), so the guarantee is unbounded. Runtime <1s.

## Next-up (intentionally not yet wired in)

- All core compute/control modules are now formally covered. Future candidates:
  the cache / coalescer datapaths and the multi-core `gpu.sv` dispatch fabric.

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
