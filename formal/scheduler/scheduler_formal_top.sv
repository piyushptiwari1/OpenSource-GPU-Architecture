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
    // Scoreboard hazard inputs: free symbolic stimulus, so the proof covers
    // every possible instruction encoding at the REQUEST stage.
    input wire [3:0]                            decoded_rd_address,
    input wire [3:0]                            decoded_rs_address,
    input wire [3:0]                            decoded_rt_address,
    input wire                                  decoded_reg_write_enable,
    input wire [1:0]                            decoded_reg_input_mux,
    input wire                                  decoded_nzp_write_enable,
    input wire                                  decoded_shared,
    // Cross-warp barrier release: driven as free symbolic stimulus so the
    // proof covers every possible coordinator behaviour.
    input wire                                  barrier_release,
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
    wire [31:0]                      perf_posted_count;
    wire [2:0]                       core_state;
    wire                             done;
    wire                             warp_at_barrier;
    wire                             posted_valid;
    wire                             posted_is_load;
    wire [3:0]                       posted_rd;
    wire [THREADS_PER_BLOCK-1:0]     posted_mask;
    wire                             posted_ack;
    wire                             issue_stall;

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
        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),
        .decoded_shared(decoded_shared),
        .barrier_release(barrier_release),
        .warp_at_barrier(warp_at_barrier),
        .fetcher_state(fetcher_state),
        .lsu_state(lsu_state),
        .posted_valid(posted_valid),
        .posted_is_load(posted_is_load),
        .posted_rd(posted_rd),
        .posted_mask(posted_mask),
        .posted_ack(posted_ack),
        .issue_stall(issue_stall),
        .current_pc(current_pc),
        .next_pc(next_pc),
        .active_mask(active_mask),
        .perf_cycle_count(perf_cycle_count),
        .perf_instr_count(perf_instr_count),
        .perf_divergence_count(perf_divergence_count),
        .perf_barrier_count(perf_barrier_count),
        .perf_posted_count(perf_posted_count),
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
