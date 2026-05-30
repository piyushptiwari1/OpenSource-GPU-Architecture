// Formal top: instantiates the DISPATCH unit as DUT and binds the property
// module. Used by SymbiYosys (formal/dispatch/dispatch.sby).
//
// All dispatch inputs are exposed as top-level ports so the engine drives them
// as free symbolic stimulus; the property module only observes outputs.

`default_nettype none
`timescale 1ns/1ns

module dispatch_formal_top #(
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire                  clk,
    input wire                  reset,
    input wire                  start,
    input wire [7:0]            thread_count,
    input wire [NUM_CORES-1:0]  core_done
);

    wire [NUM_CORES-1:0]                        core_start;
    wire [NUM_CORES-1:0]                        core_reset;
    wire [7:0]                                  core_block_id      [NUM_CORES-1:0];
    wire [$clog2(THREADS_PER_BLOCK):0]          core_thread_count  [NUM_CORES-1:0];
    wire                                        done;

    dispatch #(
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) u_dispatch (
        .clk(clk),
        .reset(reset),
        .start(start),
        .thread_count(thread_count),
        .core_done(core_done),
        .core_start(core_start),
        .core_reset(core_reset),
        .core_block_id(core_block_id),
        .core_thread_count(core_thread_count),
        .done(done)
    );

    dispatch_props #(
        .NUM_CORES(NUM_CORES)
    ) u_props (
        .clk(clk),
        .reset(reset),
        .core_start(core_start),
        .core_reset(core_reset),
        .done(done)
    );

endmodule
