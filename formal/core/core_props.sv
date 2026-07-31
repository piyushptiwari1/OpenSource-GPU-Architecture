// Formal properties for the COMPUTE CORE -- cross-module control sequencing.
//
// This is the integration ("capstone") proof: every per-module proof so far
// (fetcher, scheduler, dispatch, lsu, pc) verifies a single FSM in isolation
// under an assume-guarantee environment contract. This suite instead proves
// that those independently-verified FSMs *compose* correctly once wired
// together inside core.sv -- i.e. the producer/consumer handshakes between the
// scheduler's core_state FSM, the fetcher's fetcher_state FSM, and the per-lane
// LSUs hold on the real elaborated design, with NO environment assumptions
// (every core input is free symbolic stimulus).
//
// Wired in via formal/core/core_formal_top.sv; the synthesizable RTL is never
// touched. Verified with yosys (slang frontend) + yices2 (SymbiYosys, BMC).
//
// White-box: the scheduler/fetcher state registers are observed through plain
// hierarchical references in the formal top (core_state, fetcher_state) -- no
// bind, no exported probe port, no RTL change. The slang frontend is required
// to resolve those cross-module references (the built-in read -formal -sv
// rejects hierarchical names under `default_nettype none).
//
// Style mirrors pc_props.sv / scheduler_props.sv: immediate `assert` inside a
// clocked block with manual one-cycle history shadows (`past_*`).
//
// Proven cross-module invariants
// ------------------------------
//   fetch_valid_gated   : the core only drives program memory (program_mem_
//                         read_valid, now issued by the warp's icache on a
//                         miss) while its fetcher holds a demand or
//                         speculative request open (FETCHING/SPEC_FETCHING).
//   fetch_starts_in_fetch : the fetcher leaves IDLE (begins a fetch) only when
//                         the scheduler has entered FETCH -- the request edge of
//                         the scheduler->fetcher handshake.
//   decode_after_fetched : the scheduler advances FETCH -> DECODE only once the
//                         fetcher reports FETCHED -- the acknowledge edge of the
//                         handshake (the heart of the composition proof).
//   fetcher_clears_on_decode : the fetcher retires FETCHED (to IDLE after RET,
//                         or to SPEC_FETCHING to prefetch the predicted next
//                         instruction) only when the scheduler has reached
//                         DECODE -- the handshake teardown.
//   mem_request_gated   : a lane's LSU only drives the data-memory request lines
//                         while the scheduler is in REQUEST or WAIT, so memory
//                         traffic is confined to the memory-access window.
//   done_in_done_state  : the core's `done` output is high only in DONE.

`default_nettype none
`timescale 1ns/1ns

module core_props #(
    parameter THREADS_PER_BLOCK = 2
) (
    input wire                          clk,
    input wire                          reset,
    input wire [2:0]                    core_state,     // white-box (scheduler)
    input wire [2:0]                    fetcher_state,  // white-box (fetcher)
    input wire                          program_mem_read_valid,
    input wire [THREADS_PER_BLOCK-1:0]  data_mem_read_valid,
    input wire [THREADS_PER_BLOCK-1:0]  data_mem_write_valid,
    input wire                          done
);

    // Scheduler (core_state) encoding.
    localparam [2:0] IDLE    = 3'b000,
                     FETCH   = 3'b001,
                     DECODE  = 3'b010,
                     REQUEST = 3'b011,
                     WAIT    = 3'b100,
                     EXECUTE = 3'b101,
                     UPDATE  = 3'b110,
                     DONE    = 3'b111;

    // Fetcher (fetcher_state) encoding.
    localparam [2:0] F_IDLE          = 3'b000,
                     F_FETCHING      = 3'b001,
                     F_FETCHED       = 3'b010,
                     F_SPEC_FETCHING = 3'b011,
                     F_SPEC_READY    = 3'b100;

    // One-cycle history shadows.
    reg        past_valid;
    reg        past_reset;
    reg [2:0]  past_core_state;
    reg [2:0]  past_fetcher_state;

    initial begin
        past_valid         = 1'b0;
        past_reset         = 1'b1;
        past_core_state    = IDLE;
        past_fetcher_state = F_IDLE;
    end

    always @(posedge clk) begin
        past_valid         <= 1'b1;
        past_reset         <= reset;
        past_core_state    <= core_state;
        past_fetcher_state <= fetcher_state;
    end

    // The core's control flops have no initial value, so constrain the harness
    // to begin in reset (mirrors the per-block reset the dispatcher always
    // pulses before launching a block on this core).
    always @(*) begin
        if (!past_valid) begin
            assume (reset);
        end
    end

    always @(posedge clk) begin
        if (past_valid) begin
            // fetch_valid_gated: upstream program memory is only driven while
            // the fetcher holds a request open (the icache forwards misses of
            // demand fetches and speculative prefetches alike).
            assert (!program_mem_read_valid
                    || fetcher_state == F_FETCHING
                    || fetcher_state == F_SPEC_FETCHING);

            // mem_request_gated: a lane only drives the data-memory request
            // lines inside the scheduler's memory-access window (REQUEST/WAIT).
            if (data_mem_read_valid != '0 || data_mem_write_valid != '0) begin
                assert (core_state == REQUEST || core_state == WAIT);
            end

            // done_in_done_state: `done` is high only in DONE.
            if (done) begin
                assert (core_state == DONE);
            end

            // ---- scheduler <-> fetcher handshake (edges) -------------------
            if (!past_reset) begin
                // fetch_starts_in_fetch: IDLE -> FETCHING only from core FETCH.
                if (past_fetcher_state == F_IDLE
                    && fetcher_state == F_FETCHING) begin
                    assert (past_core_state == FETCH);
                end

                // decode_after_fetched: FETCH -> DECODE only once FETCHED.
                if (past_core_state == FETCH && core_state == DECODE) begin
                    assert (past_fetcher_state == F_FETCHED);
                end

                // fetcher_clears_on_decode: FETCHED is left (for IDLE after a
                // RET, or for SPEC_FETCHING to start the speculative prefetch)
                // only while the scheduler is in DECODE.
                if (past_fetcher_state == F_FETCHED
                    && (fetcher_state == F_IDLE
                        || fetcher_state == F_SPEC_FETCHING)) begin
                    assert (past_core_state == DECODE);
                end
            end
        end
    end

endmodule
