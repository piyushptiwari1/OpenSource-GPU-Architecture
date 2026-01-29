Test Plan for Tiny-GPU Fixes

1. Controller Arbitration Verification
- Objective: Verify that the new arbitration logic correctly handles multiple simultaneous requests without race conditions.
- Test Case 1.1: Single requester (LSU)
  - Assert consumer_read_valid[0].
  - Check controller sets mem_read_valid[0].
  - Provide mem_read_ready[0].
  - Check controller sets consumer_read_ready[0].
- Test Case 1.2: Multiple requesters
  - Assert consumer_read_valid[0], consumer_read_valid[1] simultaneously.
  - Verify only one channel (or 1 channel per available) picks up a request.
  - Verify that channel_serving_consumer bitmask correctly locks the consumer.
  - Verify that the second request is serviced after the first completes (for 1-channel controller).

2. Dispatcher Reset/Start Logic
- Objective: Verify that start/reset logic no longer has simulation/synthesis mismatches.
- Test Case 2.1: Restart
   - Run a block to completion.
   - Assert `start` again.
   - Verify `start_execution` latch works.
   - Verify `core_reset` pulses correctly (non-blocking).

3. Scheduler PC Logic
- Objective: Verify thread activity does not corrupt main PC execution.
- Test Case 3.1: Partial Block
  - Configure `thread_count = 1` (Threads per block = 4).
  - Threads 1,2,3 are inactive (`enable`=0 in `core.sv` instance).
  - Verify `scheduler` fetches correct PC instructions via `next_pc[0]`.
  - Prior implementation would fail here reading `next_pc[3]`.

4. Synthesis Check
- Objective: Ensure standard tools accept the code.
- Run `sv2v` (if available) or `yosys` read check.
- Check for "Mixed Blocking/Non-blocking" warnings.
- Check for "Multi-driven net" errors.
