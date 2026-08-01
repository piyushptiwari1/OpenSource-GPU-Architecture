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
//
// Scoreboarded issue (posted memory operations)
// ---------------------------------------------
// Plain global LDR/STR no longer hold the warp in WAIT. They are POSTED:
// the LSUs launch the access, the instruction retires its PC in UPDATE
// immediately (a posted LDR's register write is deferred), and the warp
// keeps fetching/executing subsequent instructions while the memory access
// is in flight. A one-entry scoreboard guards correctness at issue (in the
// REQUEST stage):
//   RAW  : the next instruction reads the posted load's destination register
//   WAW  : the next instruction writes the posted load's destination
//   structural : the next instruction is itself a memory operation
//   drain      : RET / BAR must wait until all posted work has landed
// Any of these holds the warp in REQUEST until the posted op completes.
// Completion is detected from the posted lanes' LSU states; the deferred
// register write is committed through a dedicated posted write port and the
// scoreboard is cleared one cycle before the stalled instruction re-reads
// its operands, so it always observes the fresh value. Atomics and shared-
// memory accesses keep the original synchronous WAIT path.
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
    // Scoreboard hazard inputs: register fields and control of the
    // instruction currently in REQUEST, used to detect RAW/WAW against the
    // posted operation and to derive whether rs/rt are actually read.
    input [3:0] decoded_rd_address,
    input [3:0] decoded_rs_address,
    input [3:0] decoded_rt_address,
    input decoded_reg_write_enable,
    input [1:0] decoded_reg_input_mux,
    input decoded_nzp_write_enable,
    // Shared-memory ops (LDS/STS) are single-cycle islands: never posted.
    input decoded_shared,
    // BAR (block-wide barrier): when asserted in UPDATE, the active lanes have
    // reached a barrier and are held until every live lane arrives.
    input decoded_barrier,

    // Cross-warp barrier coordination. A BAR synchronises the whole *block*,
    // which may span several warps, each run by its own scheduler instance.
    // `warp_at_barrier` is asserted while every live lane of THIS warp has
    // arrived at the barrier (or is arriving this cycle); the core-level
    // coordinator asserts `barrier_release` once every warp in the block is
    // at the barrier (or fully retired), releasing all parked lanes past the
    // BAR in the same cycle. With one warp per block the coordinator reduces
    // to `barrier_release = warp_at_barrier`, which preserves the original
    // single-warp behaviour bit-for-bit.
    input wire barrier_release,
    output wire warp_at_barrier,

    // Memory Access State
    input [2:0] fetcher_state,
    input [1:0] lsu_state [THREADS_PER_BLOCK-1:0],

    // Posted-operation (scoreboard) interface to the warp slice.
    //   posted_valid   : a posted LDR/STR is in flight
    //   posted_is_load : it is a load (deferred register writeback pending)
    //   posted_rd      : destination register of the posted load
    //   posted_mask    : lanes participating in the posted op (its active
    //                    mask at issue time - divergence-safe)
    //   posted_ack     : one-cycle pulse when every posted lane's LSU has
    //                    completed; the core commits the deferred register
    //                    write and releases the LSUs on this pulse
    //   issue_stall    : the instruction in REQUEST is hazard-blocked; the
    //                    core masks the LSUs' view of REQUEST while high so
    //                    a stalled memory op cannot launch early
    output reg  posted_valid,
    output reg  posted_is_load,
    output reg  [3:0] posted_rd,
    output reg  [THREADS_PER_BLOCK-1:0] posted_mask,
    output wire posted_ack,
    output wire issue_stall,

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
    // Posted (scoreboarded) memory operations issued by this warp.
    output reg [31:0] perf_posted_count,

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

    // Warp-level barrier arrival, exported to the core's barrier coordinator:
    // either every live lane is already parked at the BAR (cross-warp hold),
    // or the lanes arriving in this UPDATE complete the warp's arrival.
    assign warp_at_barrier = (live_mask != '0) && (
        ((thread_at_barrier & live_mask) == live_mask)
        || (core_state == UPDATE && decoded_barrier
            && ((live_mask & ~(thread_at_barrier | active_mask)) == '0)));

    // ---- Scoreboard hazard detection (combinational, REQUEST stage) ----
    // Which operand registers does the current instruction actually read?
    // Derived from the decoded control vector so CONST/BRnzp immediates that
    // merely alias a register index can never cause a false stall.
    wire uses_alu = (decoded_reg_write_enable && decoded_reg_input_mux == 2'b00)
                    || decoded_nzp_write_enable;              // arithmetic or CMP
    wire reads_rs = uses_alu || decoded_mem_read_enable || decoded_mem_write_enable;
    wire reads_rt = uses_alu || decoded_mem_write_enable;     // STR data / ALU rt

    // Only plain global LDR / STR are posted. Atomics assert both mem
    // enables; shared ops assert decoded_shared - both keep the WAIT path.
    wire is_postable = (decoded_mem_read_enable ^ decoded_mem_write_enable)
                       && !decoded_shared;

    wire hazard_raw = posted_valid && posted_is_load
                      && ((reads_rs && decoded_rs_address == posted_rd)
                       || (reads_rt && decoded_rt_address == posted_rd));
    wire hazard_waw = posted_valid && posted_is_load
                      && decoded_reg_write_enable
                      && decoded_rd_address == posted_rd;
    wire hazard_struct = posted_valid
                         && (decoded_mem_read_enable || decoded_mem_write_enable);
    wire hazard_drain = posted_valid && (decoded_ret || decoded_barrier);

    assign issue_stall = (core_state == REQUEST)
                         && (hazard_raw || hazard_waw || hazard_struct || hazard_drain);

    // Posted-op completion: every participating lane's LSU has reached DONE.
    // The ack commits the deferred register write (in the core), releases the
    // posted LSUs back to IDLE, and clears the scoreboard entry at the same
    // edge. A hazard-stalled instruction re-evaluates against the REGISTERED
    // posted_valid, so it proceeds one cycle after the writeback commits and
    // its operand read is guaranteed to see the fresh value.
    //
    // Built from per-lane continuous assigns (NOT an @(*) loop over the
    // unpacked lsu_state array): Icarus does not construct a reliable
    // sensitivity list for unpacked-array element reads inside @(*), which
    // would leave the ack stuck low and deadlock the structural stall.
    wire [THREADS_PER_BLOCK-1:0] posted_lane_pending;
    genvar pg;
    generate
        for (pg = 0; pg < THREADS_PER_BLOCK; pg = pg + 1) begin : posted_track
            assign posted_lane_pending[pg] = posted_mask[pg] && (lsu_state[pg] != 2'b11);
        end
    endgenerate
    assign posted_ack = posted_valid && (posted_lane_pending == '0);

    integer m;
    always @(posedge clk) begin 
        if (reset) begin
            core_state <= IDLE;
            done <= 0;
            thread_done <= '0;
            thread_at_barrier <= '0;
            posted_valid <= 0;
            posted_is_load <= 0;
            posted_rd <= 0;
            posted_mask <= '0;
            for (m = 0; m < THREADS_PER_BLOCK; m = m + 1) begin
                thread_pc[m] <= 8'b0;
            end
        end else begin 
            // Retire the posted operation once every posted lane's LSU is
            // DONE (the core commits the deferred write on the same edge).
            if (posted_ack) begin
                posted_valid <= 0;
                posted_is_load <= 0;
            end
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
                        if (valid_mask == '0) begin
                            // Empty warp: the block is smaller than a full
                            // complement of warps, and no lane in this warp is
                            // valid. Retire immediately so the core's done/
                            // barrier logic never waits on lanes that do not
                            // exist.
                            done <= 1;
                            core_state <= DONE;
                        end else begin
                            // current_pc / active_mask are already driven
                            // combinationally; just begin fetching.
                            core_state <= FETCH;
                        end
                    end
                end
                FETCH: begin 
                    if (active_mask == '0) begin
                        // Cross-warp barrier hold: every live lane of this warp
                        // is parked at a BAR waiting for the other warps of the
                        // block. Release them together once the coordinator
                        // signals that the whole block has arrived.
                        if (barrier_release && (thread_at_barrier & live_mask) != '0) begin
                            for (m = 0; m < THREADS_PER_BLOCK; m = m + 1) begin
                                if (thread_at_barrier[m] && live_mask[m]) begin
                                    thread_pc[m] <= thread_pc[m] + 1;
                                end
                            end
                            thread_at_barrier <= '0;
                        end
                    end else if (fetcher_state == 3'b010) begin 
                        // Move on once fetcher_state = FETCHED
                        core_state <= DECODE;
                    end
                end
                DECODE: begin
                    // Decode is synchronous so we move on after one cycle
                    core_state <= REQUEST;
                end
                REQUEST: begin 
                    // Hazard-blocked instructions hold here until the posted
                    // operation lands (the core masks the LSUs' view of
                    // REQUEST while issue_stall is high, so a blocked memory
                    // op cannot launch). Registers re-latch rs/rt every
                    // stalled cycle, so operands are fresh on release.
                    if (issue_stall) begin
                        // hold in REQUEST
                    end else if (is_postable) begin
                        // POST the memory op: the LSUs of the active lanes
                        // have just launched it; record it in the scoreboard
                        // and proceed without waiting. A posted LDR's
                        // register write is deferred until completion (the
                        // core suppresses the MEMORY-mux write in UPDATE).
                        posted_valid <= 1;
                        posted_is_load <= decoded_mem_read_enable;
                        posted_rd <= decoded_rd_address;
                        posted_mask <= active_mask;
                        perf_posted_count <= perf_posted_count + 1;
                        core_state <= EXECUTE;
                    end else if (decoded_mem_read_enable || decoded_mem_write_enable) begin
                        // Atomics and shared-memory ops keep the synchronous
                        // WAIT path (atomics hold a controller address lock;
                        // shared ops complete in a cycle anyway).
                        core_state <= WAIT;
                    end else begin
                        core_state <= EXECUTE;
                    end
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
                        // too arrive. Once every live lane of this warp has
                        // arrived, the warp signals `warp_at_barrier`; only when
                        // the block-level coordinator confirms every OTHER warp
                        // has arrived too (`barrier_release`) is the whole block
                        // stepped past the BAR in lockstep.
                        if ((live_mask & ~(thread_at_barrier | active_mask)) == '0) begin
                            // This warp's last arrivals are here.
                            if (barrier_release) begin
                                // Whole block arrived: release every parked lane
                                // and step them past the BAR together.
                                for (m = 0; m < THREADS_PER_BLOCK; m = m + 1) begin
                                    if ((thread_at_barrier[m] | active_mask[m]) && live_mask[m]) begin
                                        thread_pc[m] <= thread_pc[m] + 1;
                                    end
                                end
                                thread_at_barrier <= '0;
                            end else begin
                                // Other warps of the block are still on their
                                // way: park the arrivals and hold in FETCH with
                                // an empty active mask (cross-warp stall).
                                thread_at_barrier <= thread_at_barrier | active_mask;
                                perf_barrier_count <= perf_barrier_count + 1;
                            end
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
            perf_posted_count <= 32'b0;
        end
    end
endmodule
