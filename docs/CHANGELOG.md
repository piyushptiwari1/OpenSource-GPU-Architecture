# Changelog

## [Unreleased] - 2026-01-29

### Fixed
- **Synthesis**: Fixed "multiple driver" race condition in `src/controller.sv` arbitration logic. Replaced blocking assignments in sequential loops with proper next-state variable patterns.
- **Synthesis**: Fixed mixed blocking/non-blocking assignments in `src/dispatch.sv` to ensure deterministic behavior.
- **Syntax**: Fixed typo in `src/dcr.sv` (`device_conrol_register` -> `device_control_register`).
- **Syntax**: Fixed trailing comma in `src/gpu.sv` module instantiation which caused syntax errors in some parsers.

### Security
- **Arbitration**: The controller now strictly enforces one-consumer-per-channel logic using a combinatorial "next-state" vector (`next_channel_serving_consumer`) before registering the state.
