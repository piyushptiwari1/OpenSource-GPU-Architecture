# Changelog

## [Unreleased] - 2026-01-29

### Fixed
- **Scheduler**: Fixed critical bug where logic relied on the `next_pc` of the last thread in the block. Changed to use Thread 0 (`next_pc[0]`) which is guaranteed to be active. Previously, if the block was partially full, the scheduler would read a stale/zero PC from inactive threads.
- **Synthesis**: Converted all internal signal declarations in `src/core.sv` from `reg` to `wire` for signals driven by submodule instances. This fixes mixed-abstraction style and ensures compatibility with strict Verilog/SystemVerilog tools.
- **Synthesis**: Fixed "multiple driver" race condition in `src/controller.sv` arbitration logic. Replaced blocking assignments in sequential loops with proper next-state variable patterns.
- **Synthesis**: Fixed mixed blocking/non-blocking assignments in `src/dispatch.sv` to ensure deterministic behavior.
- **Syntax**: Fixed typo in `src/dcr.sv` (`device_conrol_register` -> `device_control_register`).
- **Syntax**: Fixed trailing comma in `src/gpu.sv` module instantiation which caused syntax errors in some parsers.

### Security
- **Arbitration**: The controller now strictly enforces one-consumer-per-channel logic using a combinatorial "next-state" vector (`next_channel_serving_consumer`) before registering the state.
