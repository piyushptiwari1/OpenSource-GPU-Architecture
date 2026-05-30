// Formal top: instantiates the SCHEDULER as DUT and binds the property module.
// Used by SymbiYosys (formal/scheduler/scheduler.sby).
//
// All scheduler inputs are exposed as top-level ports so the formal engine
// drives them as free (symbolic) stimulus; the property module observes the
// FSM outputs. We never drive any input here, so the proof holds for every
// possible environment.

`default_nettype none
`timescale 1ns/1ns

module scheduler_formal_top #(
    parameter THREADS_PER_BLOCK = 4
) (
    input wire                                  clk,
    input wire                                  reset,
    input wire                                  perf_reset,
    input wire                                  start,
    input wire [$clog2(THREADS_PER_BLOCK):0]    thread_count,
    input wire                                  decoded_mem_read_enable,
    input wire                                  decoded_mem_write_enable,
    input wire                                  decoded_ret,
    input wire                                  decoded_barrier,
    input wire [2:0]                            fetcher_state,
    input wire [1:0]                            lsu_state [THREADS_PER_BLOCK-1:0],
    input wire [7:0]                            next_pc   [THREADS_PER_BLOCK-1:0]
);

    wire [7:0]                       current_pc;
    wire [THREADS_PER_BLOCK-1:0]     active_mask;
    wire [31:0]                      perf_cycle_count;
    wire [31:0]                      perf_instr_count;
    wire [31:0]                      perf_divergence_count;
    wire [31:0]                      perf_barrier_count;
    wire [2:0]                       core_state;
    wire                             done;

    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) u_scheduler (
        .clk(clk),
        .reset(reset),
        .perf_reset(perf_reset),
        .start(start),
        .thread_count(thread_count),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_ret(decoded_ret),
        .decoded_barrier(decoded_barrier),
        .fetcher_state(fetcher_state),
        .lsu_state(lsu_state),
        .current_pc(current_pc),
        .next_pc(next_pc),
        .active_mask(active_mask),
        .perf_cycle_count(perf_cycle_count),
        .perf_instr_count(perf_instr_count),
        .perf_divergence_count(perf_divergence_count),
        .perf_barrier_count(perf_barrier_count),
        .core_state(core_state),
        .done(done)
    );

    scheduler_props #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) u_props (
        .clk(clk),
        .reset(reset),
        .start(start),
        .thread_count(thread_count),
        .core_state(core_state),
        .done(done),
        .active_mask(active_mask)
    );

endmodule
