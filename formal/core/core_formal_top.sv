// Formal top: instantiates the COMPUTE CORE as DUT and binds the cross-module
// property module. Used by SymbiYosys (formal/core/core.sby).
//
// Every core input is exposed as a free top-level port, so the engine drives
// the entire elaborated core (fetcher + decoder + scheduler + per-lane
// alu/lsu/registers/pc + shared memory) with unconstrained symbolic stimulus --
// there is NO environment assumption. The property module observes the two
// internal control-FSM state registers through hierarchical references
// (u_core.core_state, u_core.fetcher_state) plus the core's memory/done outputs.
//
// THREADS_PER_BLOCK is reduced to 2 to keep the multi-module state space
// tractable for BMC; the proven handshake invariants are lane-count independent.

`default_nettype none
`timescale 1ns/1ns

module core_formal_top #(
    parameter DATA_MEM_ADDR_BITS    = 8,
    parameter DATA_MEM_DATA_BITS    = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK     = 2
) (
    input  wire                                 clk,
    input  wire                                 reset,
    input  wire                                 perf_reset,
    input  wire                                 start,
    input  wire [7:0]                           block_id,
    input  wire [$clog2(THREADS_PER_BLOCK):0]   thread_count,
    input  wire                                 program_mem_read_ready,
    input  wire [PROGRAM_MEM_DATA_BITS-1:0]     program_mem_read_data,
    input  wire [THREADS_PER_BLOCK-1:0]         data_mem_read_ready,
    input  wire [DATA_MEM_DATA_BITS-1:0]        data_mem_read_data  [THREADS_PER_BLOCK-1:0],
    input  wire [THREADS_PER_BLOCK-1:0]         data_mem_write_ready
);

    // Core outputs (observed by the property module / left dangling).
    wire                                program_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0]    program_mem_read_address;
    wire [THREADS_PER_BLOCK-1:0]        data_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]       data_mem_read_address  [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0]        data_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0]       data_mem_write_address [THREADS_PER_BLOCK-1:0];
    wire [DATA_MEM_DATA_BITS-1:0]       data_mem_write_data    [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0]        data_mem_atomic;
    wire [31:0]                         perf_cycle_count;
    wire [31:0]                         perf_instr_count;
    wire [31:0]                         perf_divergence_count;
    wire [31:0]                         perf_barrier_count;
    wire                                done;

    core #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) u_core (
        .clk(clk),
        .reset(reset),
        .perf_reset(perf_reset),
        .start(start),
        .done(done),
        .block_id(block_id),
        .thread_count(thread_count),
        .program_mem_read_valid(program_mem_read_valid),
        .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready),
        .program_mem_read_data(program_mem_read_data),
        .data_mem_read_valid(data_mem_read_valid),
        .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready),
        .data_mem_read_data(data_mem_read_data),
        .data_mem_write_valid(data_mem_write_valid),
        .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data),
        .data_mem_write_ready(data_mem_write_ready),
        .data_mem_atomic(data_mem_atomic),
        .perf_cycle_count(perf_cycle_count),
        .perf_instr_count(perf_instr_count),
        .perf_divergence_count(perf_divergence_count),
        .perf_barrier_count(perf_barrier_count)
    );

    core_props #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) u_props (
        .clk(clk),
        .reset(reset),
        // White-box hierarchical references into the elaborated core: the
        // scheduler's and fetcher's state registers (no RTL change).
        .core_state(u_core.core_state),
        .fetcher_state(u_core.fetcher_state),
        .program_mem_read_valid(program_mem_read_valid),
        .data_mem_read_valid(data_mem_read_valid),
        .data_mem_write_valid(data_mem_write_valid),
        .done(done)
    );

endmodule
