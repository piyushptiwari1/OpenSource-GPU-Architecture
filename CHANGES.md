# Changes vs. upstream `adam-maj/tiny-gpu`

This fork (**OpenSource GPU Architecture**) integrates every open community PR
on the upstream repository and addresses a number of open issues.

## Pull requests merged

| Upstream PR | Subject | Status |
|-------------|---------|--------|
| #13 | Ubuntu 22.04 / iverilog 11 compatibility (`input reg` -> `input`) | merged |
| #18 | Timestamped output directory for tests | merged |
| #35 | Waveform with iverilog (`-fst`) + `Makefile.cocotb.mk` | merged |
| #38 | `Makefile.sv` for direct SV simulation (VCS / Questa) | merged |
| #39 | Improved Makefile + `iverilog_dump_*.sv` for VCD viewing | merged |
| #41 | gtkwave visualization + clock unit fixes | merged |
| #42 | Typo fix `matadd` -> `matmul` in test log | merged |
| #44 | Cache implementation on compute cores (`cache.sv`, `lsu_cached.sv`) | merged |
| #45 | cocotb v2.x compatibility | merged |
| #51 | Interactive Digital visualization (`visualization/*.dig`) | merged |
| #52 | Synthesis, logic, and verification fixes | merged |
| #53 | ALU `nzp` swap + unsigned subtract overflow fix | merged |
| #54 | Beginner-friendly RTL docs + VS Code workflows | merged (Chinese-language commentary translated to English; original technical content preserved) |
| #55 | Production SoC / enterprise modules / CI / VLSI flows | merged (preserved as additions; base RTL kept compatible) |
| #56 | Frontend (web visualization) | merged |

When the merges conflicted with each other on shared files (`Makefile`,
`src/core.sv`, `src/dcr.sv`, `test/helpers/*`, `.gitignore`), the resolution
preferred the fix that kept the test suite green:

- **iverilog 11 compatibility** (`input` instead of `input reg` on RTL ports)
  is preserved across all later merges.
- **cocotb v2.x APIs** (`COCOTB_TEST_MODULES`, `--lib-dir`, `unit=`) are used
  consistently in `test/helpers/setup.py` and the default `Makefile`.
- The unified `Makefile` keeps timestamped test output, FST/VCD waveform
  generation, and a `MODULE=` override.
- PR #55's heavy synthesis/SoC build script is preserved as `Makefile.vlsi`
  for the per-module simulation rules; the commercial ASIC/FPGA targets
  (Synopsys/Cadence/Vivado/Quartus) live under `flow/commercial/` and are
  gated on `OPENGPU_COMMERCIAL=1` (C-10).

## Issues addressed

| Upstream issue | Subject | Resolution |
|----------------|---------|------------|
| #4 | On branch divergence | Documented as future work; PR #55 ships an `src/divergence.sv` module to build on. |
| #15 | Makefile compat on Windows + cocotb | Subsumed by cocotb v2.x flow (PR #45). |
| #17 | `input reg` rejected by iverilog | Fixed by PR #13. |
| #19 | Adding branch divergence | New `src/divergence.sv` module added via PR #55. |
| #20 | Prefer `unique case` for mutually exclusive selects | Applied to `controller.sv` (channel FSM), `scheduler.sv` (core FSM), `lsu.sv` (LSU FSM, both branches), and `alu.sv` (ALU op mux). All cases have full state coverage and a defensive `default:` where state space is wider than the encoding requires. |
| #22 | Synthesis with Quartus Prime | Trailing comma + unpacked-array reset issues fixed in `dcr.sv` and `controller.sv`. |
| #25 | Scalar reset of unpacked array rejected by Quartus | `controller.sv` reset rewritten to per-element loops with explicit widths. |
| #27 | Endianness | Endianness is effectively N/A: data memory is **8-bit byte-addressed** (`DATA_MEM_DATA_BITS = 8`), and program memory is **word-addressed with one 16-bit instruction per address** — neither requires multi-byte ordering. Within an instruction word, the bit layout is MSB-first: `instruction[15:12]` opcode, `[11:8]` `Rd`, `[7:4]` `Rs`, `[3:0]` `Rt` / immediate-low (see `src/decoder.sv`). |
| #30 | Tiny DCR typo `device_conrol_register` | Fixed; identifier is now `device_control_register` everywhere. |
| #43 | Build issue with cocotb (`--prefix` removed) | Fixed by cocotb v2.x flow. |
| #46 | Tests fail with cocotb v2.x | Fixed in `Makefile` and `test/helpers/setup.py`. |
| #50 | Update docs: virtual environment | New "Recommended (Python virtual environment)" section in `README.md`. |
| #7 | No license | `LICENSE` (MIT) added at the repository root. |

Issues left intentionally open because they require external work or are out
of scope for this fork (Linux driver, RISC-V interfacing, Chisel port,
translations, hardware recommendations, ISA compiler) are tracked upstream.

## Architecture upgrades (beyond upstream)

On top of the merged community work, this fork advances the verified `gpu`
top from the original learning-level control flow to an industry-style SIMT
microarchitecture. Every feature below is integrated into the default build
(`make compile`), covered by an end-to-end cocotb test, and kept green across
the full sweep.

| Feature | RTL | Verified by |
|---------|-----|-------------|
| Per-warp-slice L1 instruction cache (direct-mapped, warm across blocks; only misses reach program memory) | `src/icache.sv`, wired in `src/core.sv` | `test/test_icache_e2e.py` (external fetch beats == misses) |
| Pipelined front-end: speculative next-line prefetch with static BTFN branch prediction, overlapped with EXECUTE/UPDATE | `src/fetcher.sv` | full sweep; matmul 491 → 349 cycles (−29%), matadd 178 → 154 (−13%) |
| `WAIT`-stage skip for non-memory instructions | `src/scheduler.sv` | full sweep |
| Multi-warp SIMT cores: block partitioned into warp slices (own fetcher + icache + decoder + scheduler), independent per-warp FSMs hide each other's memory latency | `src/core.sv` (`THREADS_PER_WARP` parameter, default = whole block) | `test/test_warp_scheduling_e2e.py`: latency-bound kernel 868 → 647 cycles (−25%), 310 measured overlap cycles |
| Cross-warp block barrier coordinator (BAR synchronises all live warps; retired warps excluded, deadlock-free) | `src/core.sv` + `src/scheduler.sv` | `test/test_warp_scheduling_e2e.py`, `test/test_barrier_e2e.py` |
| Graphics: SIMT edge-function rasterizer kernel rendering a triangle into a framebuffer region with per-pixel divergence | ISA kernel (no new RTL) | `test/test_graphics_e2e.py` |
| L2 data cache: line-interleaved home banks (structural coherence, no snooping) with write-through + update-if-resident; controller-side crossbar routes each channel to its address's home bank | `src/l2_cache.sv`, wired in `src/gpu.sv` | `test/test_l2_cache_e2e.py`: 32 loads → 1 line burst (31 hits), write-through verified beat-for-beat |
| Address-range (burst) coalescing: 4-word L2 lines filled by back-to-back sequential external reads; strided warp accesses collapse into line bursts | `src/l2_cache.sv` (FILL/FILL_GAP burst engine) | `test/test_burst_coalescing_e2e.py`: 32 strided loads → 4 bursts (16 beats, 12 sequential) under an open-row DRAM model |
| Scoreboarded issue: plain LDR/STR are posted (warp keeps executing during the access); one-entry scoreboard interlocks RAW/WAW/structural/drain hazards at REQUEST; deferred, divergence-safe register writeback on completion; `perf_posted_count` counter | `src/scheduler.sv` + `src/core.sv` + `src/lsu.sv` (op_release) + `src/registers.sv` (posted write port) | `test/test_scoreboard_e2e.py`: A/B kernels with identical instructions, software-pipelined order 40 cycles faster |
| Dispatcher lost-block fix: two cores finishing a block in the same cycle collapsed `blocks_done` increments (latent upstream bug exposed by scoreboard timing symmetry) | `src/dispatch.sv` | previously-hanging `test_graphics_e2e.py` |
| Tiny Tapeout 7 adapter test target in the main cocotb v2 flow | `src/tt_um_tiny_gpu.sv` (from PR #55) | `make test_tt_adapter` (5 subtests) |
| Top-level observability: `perf_icache_hit/miss_count` counters joining the existing cycle/instr/divergence/barrier/coalesce counters | `src/gpu.sv` | perf/e2e tests |

The formal harnesses (`formal/fetcher`, `formal/scheduler`, `formal/core`)
were extended for the new speculative fetcher states, the WAIT-skip edge, and
the per-warp program-memory port shape.

## Author / credits

The original architecture, ISA, and Verilog source are by
[Adam Majmudar (@adam-maj)](https://github.com/adam-maj). This fork only
integrates community contributions and applies fixes for issues raised on the
upstream tracker.
