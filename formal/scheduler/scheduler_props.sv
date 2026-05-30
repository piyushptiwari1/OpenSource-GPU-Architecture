// Formal properties for the SCHEDULER core FSM.
//
// Wired in via formal/scheduler/scheduler_formal_top.sv so we never perturb
// the synthesizable RTL. Verified with yosys + yices2 (SymbiYosys).
//
// Style: yosys' default formal frontend supports immediate ``assert``/``assume``
// statements inside ``always`` blocks (not module-scope concurrent
// ``assert property``). We shadow the previous-cycle values manually via
// ``past_*`` flops so every check is pure combinational, matching dcr_props.sv.
//
// The scheduler is a single-warp-per-block SIMT controller: one 8-state FSM
// (IDLE/FETCH/DECODE/REQUEST/WAIT/EXECUTE/UPDATE/DONE) drives the whole block.
// These are the standard safety invariants for such a control FSM.
//
// Properties proven here
// ----------------------
//   reset_state      : one cycle after reset, the FSM is IDLE with done = 0.
//   legal_transition : every state only advances along a legal FSM edge.
//   start_gate       : IDLE is only left when `start` was asserted.
//   done_implies_done_state : `done` is high only while in the DONE state.
//   done_sticky      : once `done` is set it stays set until reset.
//   active_subset    : every active lane is a valid lane (index < thread_count).

`default_nettype none
`timescale 1ns/1ns

module scheduler_props #(
    parameter THREADS_PER_BLOCK = 4
) (
    input wire                                  clk,
    input wire                                  reset,
    input wire                                  start,
    input wire [$clog2(THREADS_PER_BLOCK):0]    thread_count,
    input wire [2:0]                            core_state,
    input wire                                  done,
    input wire [THREADS_PER_BLOCK-1:0]          active_mask
);

    localparam [2:0] IDLE    = 3'b000,
                     FETCH   = 3'b001,
                     DECODE  = 3'b010,
                     REQUEST = 3'b011,
                     WAIT    = 3'b100,
                     EXECUTE = 3'b101,
                     UPDATE  = 3'b110,
                     DONE    = 3'b111;

    // One-cycle history shadows.
    reg        past_valid;
    reg        past_reset;
    reg        past_start;
    reg [2:0]  past_core_state;
    reg        past_done;

    initial begin
        past_valid      = 1'b0;
        past_reset      = 1'b1;
        past_start      = 1'b0;
        past_core_state = IDLE;
        past_done       = 1'b0;
    end

    always @(posedge clk) begin
        past_valid      <= 1'b1;
        past_reset      <= reset;
        past_start      <= start;
        past_core_state <= core_state;
        past_done       <= done;
    end

    // The FSM has no initial value, so constrain the harness to begin in reset.
    // This mirrors how the dispatcher always pulses `reset` before `start`.
    always @(*) begin
        if (!past_valid) begin
            assume (reset);
        end
    end

    integer i;
    always @(posedge clk) begin
        if (past_valid) begin
            // reset_state: a reset cycle drives the FSM to IDLE with done low.
            if (past_reset) begin
                assert (core_state == IDLE);
                assert (done == 1'b0);
            end

            // legal_transition / start_gate: outside reset the FSM only moves
            // along the edges defined by the RTL.
            if (!past_reset) begin
                case (past_core_state)
                    IDLE: begin
                        // start_gate: stay IDLE unless start was asserted.
                        if (!past_start)
                            assert (core_state == IDLE);
                        else
                            assert (core_state == IDLE || core_state == FETCH);
                    end
                    FETCH:   assert (core_state == FETCH || core_state == DECODE);
                    DECODE:  assert (core_state == REQUEST);
                    REQUEST: assert (core_state == WAIT);
                    WAIT:    assert (core_state == WAIT || core_state == EXECUTE);
                    EXECUTE: assert (core_state == UPDATE);
                    UPDATE:  assert (core_state == FETCH || core_state == DONE);
                    DONE:    assert (core_state == DONE);
                endcase
            end

            // done_sticky: once done is asserted it stays asserted until reset.
            // Only checked across non-reset cycles (reset legitimately clears it).
            if (!past_reset && !reset && past_done) begin
                assert (done == 1'b1);
            end

            // done_implies_done_state: `done` only ever co-occurs with DONE.
            assert (!done || core_state == DONE);

            // active_subset: an active lane is always a valid lane for the block.
            for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin
                if (active_mask[i])
                    assert (i < thread_count);
            end
        end
    end

endmodule
