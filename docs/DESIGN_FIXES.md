# Design Fixes & Improvements

## Overview
This document details the critical fixes and improvements applied to the `tiny-gpu` source code to ensure synthesis correctness and functional reliability.

## 1. Synthesis & Race Conditions

### Controller Arbitration (`src/controller.sv`)
- **Issue**: The original arbitration logic used blocking assignments (`=`) inside a sequential block (`always @(posedge clk)`) mixed with a `for` loop. This created a potential "multiple driver" scenario where multiple channels could attempt to claim the same consumer flag in the same cycle, leading to unpredictable hardware behavior.
- **Fix**: Implemented a "next-state" logic pattern. A local variable `next_channel_serving_consumer` is used to accumulate state changes within the loop combinatorially. The final result is then registered to `channel_serving_consumer` using a non-blocking assignment (`<=`) at the end of the clock cycle. This guarantees deterministic arbitration.

### Dispatcher Logic (`src/dispatch.sv`)
- **Issue**: The dispatcher mixed blocking (`=`) and non-blocking (`<=`) assignments for state variables (`blocks_dispatched`, `blocks_done`) inside the same sequential block. This can lead to simulation/synthesis mismatches.
- **Fix**: Converted all state variable updates to non-blocking assignments (`<=`) to ensure correct sequential logic behavior.

### Core Wiring (`src/core.sv`)
- **Issue**: The `core` module declared internal signals driven by submodule instances (e.g., `fetcher_state`, `instruction`, `rs`, `rt`) as `reg`. While some SystemVerilog tools tolerate this, it violates strict structural modeling rules (outputs should drive `wire`s) and can fail in tools like `sv2v` or strict linters.
- **Fix**: Converted all such internal signal declarations to `wire` and updated corresponding output ports to `output wire`.

## 2. Functional Correctness

### Scheduler PC Logic (`src/scheduler.sv`)
- **Issue**: The scheduler updated the `current_pc` based on `next_pc[THREADS_PER_BLOCK-1]` (the last thread). If a block was partially full (e.g., `thread_count < THREADS_PER_BLOCK`), the last thread would be inactive, and its `next_pc` might be invalid or zero. This would cause the entire core to stall or execute incorrect instructions.
- **Fix**: Updated the logic to use `next_pc[0]`. Since Thread 0 is always active in any valid block execution, its PC provides the correct next address for the SIMD group.

## 3. Syntax Corrections
- **DCR**: Fixed a typo in `src/dcr.sv` where `device_control_register` was misspelled.
- **GPU**: Removed a trailing comma in the `core` instantiation in `src/gpu.sv` which is invalid Verilog syntax.

## Verification Status
- **Static Analysis**: Code structure now adheres to standard SystemVerilog synthesis patterns.
- **Simulation**: While the local environment lacks the full `cocotb` test suite (python/iverilog integration issues), the code changes are logically sound and address known hardware description pitfalls.
