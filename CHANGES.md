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
  rather than overwriting the simulation flow.

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

## Author / credits

The original architecture, ISA, and Verilog source are by
[Adam Majmudar (@adam-maj)](https://github.com/adam-maj). This fork only
integrates community contributions and applies fixes for issues raised on the
upstream tracker.
