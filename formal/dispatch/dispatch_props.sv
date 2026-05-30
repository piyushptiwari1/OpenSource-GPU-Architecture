// Formal properties for the BLOCK DISPATCH handshake.
//
// Wired in via formal/dispatch/dispatch_formal_top.sv; never perturbs the
// synthesizable RTL. Verified with yosys + yices2 (SymbiYosys, k-induction).
//
// Uses the `slang` frontend (dispatch has unpacked-array ports). Style matches
// the other property modules: immediate `assert` in a clocked block with manual
// `past_*` history shadows.
//
// The dispatcher hands blocks to cores over a per-core start/reset/done
// handshake. These are the port-observable safety invariants (no internal
// probes, so no RTL change / bind needed):
//
//   reset_state       : after reset, done is low and every core is held in
//                       reset with start deasserted.
//   start_reset_mutex : a core is never simultaneously started and reset --
//                       the two phases of the per-core handshake are exclusive.
//   done_sticky       : once the kernel reports done it stays done until reset
//                       (monotonic completion).
//
// Proof mode: BMC (bounded) from the reset state, not k-induction. The EDA
// `start_execution` hack in dispatch.sv makes start_reset_mutex true for every
// reachable state but not 1-step inductive (an *unreachable* state with
// start_execution=0 while a core is already started would momentarily set both
// core_reset and core_start). Proving it by induction would need to probe the
// internal start_execution register (bind / RTL change), which we deliberately
// avoid; BMC over the reachable states is the same bounded guarantee the dcr
// proof provides.

`default_nettype none
`timescale 1ns/1ns

module dispatch_props #(
    parameter NUM_CORES = 2
) (
    input wire                      clk,
    input wire                      reset,
    input wire [NUM_CORES-1:0]      core_start,
    input wire [NUM_CORES-1:0]      core_reset,
    input wire                      done
);

    // One-cycle history shadows.
    reg        past_valid;
    reg        past_reset;
    reg        past_done;

    initial begin
        past_valid = 1'b0;
        past_reset = 1'b1;
        past_done  = 1'b0;
    end

    always @(posedge clk) begin
        past_valid <= 1'b1;
        past_reset <= reset;
        past_done  <= done;
    end

    // The dispatcher flops have no initial value, so constrain the harness to
    // begin in reset (the GPU always asserts reset before start).
    always @(*) begin
        if (!past_valid) begin
            assume (reset);
        end
    end

    integer i;
    always @(posedge clk) begin
        if (past_valid) begin
            // reset_state: a reset cycle parks every core (reset high, start low)
            // and clears done.
            if (past_reset) begin
                assert (done == 1'b0);
                for (i = 0; i < NUM_CORES; i = i + 1) begin
                    assert (core_reset[i] == 1'b1);
                    assert (core_start[i] == 1'b0);
                end
            end

            // done_sticky: completion is monotonic until reset.
            if (!past_reset && !reset && past_done) begin
                assert (done == 1'b1);
            end

            // start_reset_mutex: the start and reset phases of the per-core
            // handshake never overlap.
            for (i = 0; i < NUM_CORES; i = i + 1) begin
                assert (!(core_start[i] && core_reset[i]));
            end
        end
    end

endmodule
