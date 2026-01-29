# Changelog

## [Unreleased] - 2026-01-29

### Fixed
- **Scheduler**: Fixed critical logic bug in `src/scheduler.sv` where `any_lsu_waiting` was declared as a static `reg` variable. It has been replaced with `logic` and proper procedural assignment to ensure it resets every clock cycle.
- **Scheduler**: Fixed syntax error (trailing comma) in `src/scheduler.sv` parameter list.
- **Scheduler**: Fixed critical bug where logic relied on the `next_pc` of the last thread in the block. Changed to use Thread 0 (`next_pc[0]`) which is guaranteed to be active.
- **Synchronization**: Fixed "multiple driver" race condition in `src/controller.sv` arbitration logic using strict next-state buffering.
- **Functionality**: Fixed DCR register variable name typo (`device_conrol_register` -> `device_control_register`) and removed invalid trailing comma in port list.
- **Synthesis**: Converted `src/core.sv` internal `reg` signals to `wire` for correct structural modeling.
- **Synthesis**: Fixed mixed blocking/non-blocking assignments in `src/dispatch.sv`.
- **Syntax**: Fixed trailing comma in `src/gpu.sv` module instantiation.

### Security
- **Arbitration**: The controller now strictly enforces one-consumer-per-channel logic.
