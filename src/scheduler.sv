`default_nettype none
`timescale 1ns/1ns

// SCHEDULER
// > Manages the entire control flow of a single compute core processing 1 block
// 1. FETCH - Retrieve instruction at current program counter (PC) from program memory
// 2. DECODE - Decode the instruction into the relevant control signals
// 3. REQUEST - If we have an instruction that accesses memory, trigger the async memory requests from LSUs
// 4. WAIT - Wait for all async memory requests to resolve (if applicable)
// 5. EXECUTE - Execute computations on retrieved data from registers / memory
// 6. UPDATE - Update register values (including NZP register) and program counter
// > Each core has it's own scheduler where multiple threads can be processed with
//   the same control flow at once.
//
// Branch divergence (min-PC reconvergence)
// ----------------------------------------
// Each thread lane keeps its OWN program counter (`thread_pc[i]`). On every
// step the scheduler executes the subset of not-yet-retired lanes that sit at
// the *minimum* PC, and exposes that subset as `active_mask`. Lanes parked at a
// higher PC are masked off (frozen) until the active lanes catch up to them,
// at which point they automatically reconverge into the same `active_mask`.
//
// This is the classic "lowest-PC-first" SIMT reconvergence model. It is correct
// for reducible (structured) control flow and needs no explicit IPDOM stack.
// For kernels with no data-dependent branches (e.g. matadd/matmul) every lane
// always shares a single PC, so `active_mask` is simply all valid lanes every
// cycle and the behaviour is identical to the original naive scheduler.
module scheduler #(
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    // Global GPU reset. Unlike `reset` (which the dispatcher pulses per block to
    // reuse a core), `perf_reset` is only asserted on a full GPU reset, so the
    // performance counters accumulate across every block this core processes.
    input wire perf_reset,
    input wire start,

    // Block metadata
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,

    // Control Signals
    input decoded_mem_read_enable,
    input decoded_mem_write_enable,
    input decoded_ret,
    // BAR (block-wide barrier): when asserted in UPDATE, the active lanes have
    // reached a barrier and are held until every live lane arrives.
    input decoded_barrier,

    // Memory Access State
    input [2:0] fetcher_state,
    input [1:0] lsu_state [THREADS_PER_BLOCK-1:0],

    // Current & Next PC
    output reg [7:0] current_pc,
    input [7:0] next_pc [THREADS_PER_BLOCK-1:0],

    // Per-lane execution mask (which lanes execute this step)
    output reg [THREADS_PER_BLOCK-1:0] active_mask,

    // Performance counters (block-private, monotonic until reset). Exposed so a
    // testbench / DCR readout can observe SIMT behaviour:
    //   perf_cycle_count      : active cycles (core not IDLE and not DONE)
    //   perf_instr_count      : warp-instructions retired (one per UPDATE)
    //   perf_divergence_count : steps where active lanes were a strict subset
    //                           of live lanes (a real divergence)
    //   perf_barrier_count    : BAR partial-arrival stalls (lanes parked)
    output reg [31:0] perf_cycle_count,
    output reg [31:0] perf_instr_count,
    output reg [31:0] perf_divergence_count,
    output reg [31:0] perf_barrier_count,

    // Execution State
    output reg [2:0] core_state,
    output reg done
);
    localparam IDLE = 3'b000, // Waiting to start
        FETCH = 3'b001,       // Fetch instructions from program memory
        DECODE = 3'b010,      // Decode instructions into control signals
        REQUEST = 3'b011,     // Request data from registers or memory
        WAIT = 3'b100,        // Wait for response from memory if necessary
        EXECUTE = 3'b101,     // Execute ALU and PC calculations
        UPDATE = 3'b110,      // Update registers, NZP, and PC
        DONE = 3'b111;        // Done executing this block

    // Per-lane divergence state
    // > thread_pc[i]   : program counter of lane i
    // > thread_done[i] : 1 once lane i has executed RET
    reg [7:0] thread_pc [THREADS_PER_BLOCK-1:0];
    reg [THREADS_PER_BLOCK-1:0] thread_done;

    // Per-lane barrier state
    // > thread_at_barrier[i] : 1 while lane i is parked at a BAR waiting for the
    //   rest of the block. Barrier-parked lanes are excluded from PC selection
    //   (like a done lane) until the whole block arrives and is released.
    reg [THREADS_PER_BLOCK-1:0] thread_at_barrier;

    // Combinational reconvergence: pick the minimum PC among lanes that are
    // valid (within thread_count), not retired, and not parked at a barrier,
    // then mark every such lane sitting at that PC as active. `all_done` is high
    // once no valid lane remains.
    reg [7:0] min_pc;
    reg [THREADS_PER_BLOCK-1:0] valid_mask;
    reg [THREADS_PER_BLOCK-1:0] live_mask;       // valid & not retired
    reg [THREADS_PER_BLOCK-1:0] runnable_mask;   // live & not at barrier
    reg [THREADS_PER_BLOCK-1:0] next_active_mask;
    reg all_done;
    integer k;
    always @(*) begin
        // Lanes 0..thread_count-1 are valid for this block.
        valid_mask = '0;
        for (k = 0; k < THREADS_PER_BLOCK; k = k + 1) begin
            valid_mask[k] = (k < thread_count);
        end

        live_mask = valid_mask & ~thread_done;
        runnable_mask = live_mask & ~thread_at_barrier;

        // Minimum PC over runnable lanes (valid, not done, not barrier-parked).
        min_pc = 8'hFF;
        for (k = 0; k < THREADS_PER_BLOCK; k = k + 1) begin
            if (runnable_mask[k] && thread_pc[k] < min_pc) begin
                min_pc = thread_pc[k];
            end
        end

        // Active lanes = runnable lanes parked at the minimum PC.
        next_active_mask = '0;
        for (k = 0; k < THREADS_PER_BLOCK; k = k + 1) begin
            next_active_mask[k] = runnable_mask[k] && (thread_pc[k] == min_pc);
        end

        all_done = (live_mask == '0);

        // current_pc / active_mask are combinational projections of the
        // per-lane state: the fetcher samples a stable current_pc because
        // thread_pc only changes at the UPDATE clock edge.
        current_pc = min_pc;
        active_mask = next_active_mask;
    end

    integer m;
    always @(posedge clk) begin 
        if (reset) begin
            core_state <= IDLE;
            done <= 0;
            thread_done <= '0;
            thread_at_barrier <= '0;
            for (m = 0; m < THREADS_PER_BLOCK; m = m + 1) begin
                thread_pc[m] <= 8'b0;
            end
        end else begin 
            // Active-cycle counter: tick whenever the core is doing work
            // (i.e. has been started and has not finished the block).
            if (core_state != IDLE && core_state != DONE) begin
                perf_cycle_count <= perf_cycle_count + 1;
            end

            // Core FSM: states are mutually exclusive and the 3-bit encoding
            // covers all 8 values, so `unique case` lets the synthesizer infer
            // a clean state machine and warn on any overlap (issue #20).
            unique case (core_state)
                IDLE: begin
                    // Here after reset (before kernel is launched, or after previous block has been processed)
                    if (start) begin 
                        // current_pc / active_mask are already driven
                        // combinationally; just begin fetching.
                        core_state <= FETCH;
                    end
                end
                FETCH: begin 
                    // Move on once fetcher_state = FETCHED
                    if (fetcher_state == 3'b010) begin 
                        core_state <= DECODE;
                    end
                end
                DECODE: begin
                    // Decode is synchronous so we move on after one cycle
                    core_state <= REQUEST;
                end
                REQUEST: begin 
                    // Request is synchronous so we move on after one cycle
                    core_state <= WAIT;
                end
                WAIT: begin
                    // Wait for all LSUs to finish their request before continuing
                    logic any_lsu_waiting;
                    any_lsu_waiting = 1'b0;
                    
                    for (int i = 0; i < THREADS_PER_BLOCK; i++) begin
                        // Make sure no lsu_state = REQUESTING or WAITING
                        if (lsu_state[i] == 2'b01 || lsu_state[i] == 2'b10) begin
                            any_lsu_waiting = 1'b1;
                            break;
                        end
                    end

                    // If no LSU is waiting for a response, move onto the next stage
                    if (!any_lsu_waiting) begin
                        core_state <= EXECUTE;
                    end
                end
                EXECUTE: begin
                    // Execute is synchronous so we move on after one cycle
                    core_state <= UPDATE;
                end
                UPDATE: begin 
                    // One warp-instruction is retired each time we pass through
                    // UPDATE. If the active lanes were a strict subset of the
                    // live lanes, this step ran under divergence -- count it.
                    perf_instr_count <= perf_instr_count + 1;
                    if ((live_mask & ~active_mask) != '0) begin
                        perf_divergence_count <= perf_divergence_count + 1;
                    end

                    if (decoded_ret) begin 
                        // The active lanes have reached RET and retire. Other
                        // (diverged) lanes may still have work to do, so only
                        // finish the block once every valid lane is done.
                        thread_done <= thread_done | active_mask;
                        if ((valid_mask & ~(thread_done | active_mask)) == '0) begin
                            // Every valid lane has now retired.
                            done <= 1;
                            core_state <= DONE;
                        end else begin
                            // Reconverge onto the remaining lanes' minimum PC.
                            core_state <= FETCH;
                        end
                    end else if (decoded_barrier) begin
                        // The active lanes have reached a BAR. Park them at the
                        // barrier; runnable lanes that are still behind keep
                        // executing (they are now the new minimum PC) until they
                        // too arrive. Once every live lane has arrived, release
                        // the whole block together past the barrier.
                        if ((live_mask & ~(thread_at_barrier | active_mask)) == '0) begin
                            // Last arrivals complete the barrier: release all
                            // parked lanes and step them past the BAR in lockstep.
                            for (m = 0; m < THREADS_PER_BLOCK; m = m + 1) begin
                                if ((thread_at_barrier[m] | active_mask[m]) && live_mask[m]) begin
                                    thread_pc[m] <= thread_pc[m] + 1;
                                end
                            end
                            thread_at_barrier <= '0;
                        end else begin
                            // Hold the lanes that just arrived; do not advance
                            // their PC. Lanes still behind will run next.
                            thread_at_barrier <= thread_at_barrier | active_mask;
                            // Count a barrier stall: the block could not proceed
                            // because not every live lane had reached the BAR.
                            perf_barrier_count <= perf_barrier_count + 1;
                        end
                        core_state <= FETCH;
                    end else begin 
                        // Advance only the lanes that executed this step; parked
                        // (higher-PC) lanes keep their PC and reconverge later.
                        for (m = 0; m < THREADS_PER_BLOCK; m = m + 1) begin
                            if (active_mask[m]) begin
                                thread_pc[m] <= next_pc[m];
                            end
                        end

                        // Update is synchronous so we move on after one cycle
                        core_state <= FETCH;
                    end
                end
                DONE: begin 
                    // no-op
                end
            endcase
        end

        // Performance counters are cleared only on a full GPU reset, so they
        // survive the per-block `reset` the dispatcher uses to reuse this core
        // and therefore accumulate over every block the core executes.
        if (perf_reset) begin
            perf_cycle_count <= 32'b0;
            perf_instr_count <= 32'b0;
            perf_divergence_count <= 32'b0;
            perf_barrier_count <= 32'b0;
        end
    end
endmodule
