`default_nettype none
`timescale 1ns/1ns

// COMPUTE CORE
// > Handles processing 1 block at a time
// > The core also has it's own scheduler to manage control flow
// > Each core contains 1 fetcher & decoder, and register files, ALUs, LSUs, PC for each thread
//
// Beginner notes:
// 1. This is one of the most rewarding files to re-read in the whole design,
//    because it stitches the shared control path and the per-thread datapath together.
// 2. `fetcher`, `decoder`, and `scheduler` are instantiated once per core, while
//    `registers`, `alu`, `lsu`, and `pc` are replicated once per thread lane.
// 3. Read declarations like `wire [7:0] next_pc [THREADS_PER_BLOCK-1:0];` in two parts:
//    each element is 8 bits, and there are `THREADS_PER_BLOCK` elements in total.
// 4. `generate for (...) begin : threads` is NOT a runtime loop; it tells the
//    synthesizer to replicate the hardware structures inside it at elaboration time.
// 5. If you are new to Verilog, treat this module as a wiring diagram first --
//    follow the signal names to see how submodules connect to each other before
//    trying to reason cycle-by-cycle.
module core #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,
    // Full-GPU reset, used only to clear the performance counters (the regular
    // `reset` is pulsed by the dispatcher per block to reuse this core).
    input wire perf_reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Block Metadata
    input wire [7:0] block_id,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,

    // Program Memory
    output reg program_mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input program_mem_read_ready,
    input [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,

    // Data Memory
    output reg [THREADS_PER_BLOCK-1:0] data_mem_read_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [THREADS_PER_BLOCK-1:0],
    input [THREADS_PER_BLOCK-1:0] data_mem_read_ready,
    input [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [THREADS_PER_BLOCK-1:0],
    output reg [THREADS_PER_BLOCK-1:0] data_mem_write_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [THREADS_PER_BLOCK-1:0],
    output reg [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [THREADS_PER_BLOCK-1:0],
    input [THREADS_PER_BLOCK-1:0] data_mem_write_ready,
    // Per-lane atomic flag forwarded from each LSU to the data memory controller.
    output wire [THREADS_PER_BLOCK-1:0] data_mem_atomic,

    // Performance counters (forwarded from this core's scheduler).
    output wire [31:0] perf_cycle_count,
    output wire [31:0] perf_instr_count,
    output wire [31:0] perf_divergence_count,
    output wire [31:0] perf_barrier_count
);
    // State
    // These signals are shared across the entire core: every active lane sees them.
    reg [2:0] core_state;
    reg [2:0] fetcher_state;
    reg [15:0] instruction;

    // Intermediate Signals
    // The next PC, source operands, and LSU state are kept per thread lane.
    reg [7:0] current_pc;
    wire [7:0] next_pc[THREADS_PER_BLOCK-1:0];
    // Per-lane execution mask produced by the scheduler's min-PC reconvergence:
    // active_mask[i] is high only for lanes that should execute this step.
    wire [THREADS_PER_BLOCK-1:0] active_mask;
    reg [7:0] rs[THREADS_PER_BLOCK-1:0];
    reg [7:0] rt[THREADS_PER_BLOCK-1:0];
    reg [1:0] lsu_state[THREADS_PER_BLOCK-1:0];
    reg [7:0] lsu_out[THREADS_PER_BLOCK-1:0];
    wire [7:0] alu_out[THREADS_PER_BLOCK-1:0];

    // Per-block shared memory interface (one banked island shared by all lanes).
    // Driven by each lane's LSU when it executes an LDS/STS (decoded_shared).
    wire [THREADS_PER_BLOCK-1:0] shared_read_valid;
    wire [7:0] shared_read_address [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] shared_read_ready;
    wire [7:0] shared_read_data [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] shared_write_valid;
    wire [7:0] shared_write_address [THREADS_PER_BLOCK-1:0];
    wire [7:0] shared_write_data [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] shared_write_ready;
    wire [THREADS_PER_BLOCK-1:0] shared_bank_conflict;
    // Decoded Instruction Signals
    reg [3:0] decoded_rd_address;
    reg [3:0] decoded_rs_address;
    reg [3:0] decoded_rt_address;
    reg [2:0] decoded_nzp;
    reg [7:0] decoded_immediate;

    // Decoded Control Signals
    reg decoded_reg_write_enable;           // Enable writing to a register
    reg decoded_mem_read_enable;            // Enable reading from memory
    reg decoded_mem_write_enable;           // Enable writing to memory
    reg decoded_nzp_write_enable;           // Enable writing to NZP register
    reg [1:0] decoded_reg_input_mux;        // Select input to register
    reg [1:0] decoded_alu_arithmetic_mux;   // Select arithmetic operation
    reg decoded_alu_output_mux;             // Select operation in ALU
    reg decoded_pc_mux;                     // Select source of next PC
    reg decoded_atomic_op;                  // 0=ATOMICADD, 1=ATOMICCAS
    reg decoded_barrier;                    // BAR: block-wide synchronisation
    reg decoded_shared;                     // LDS/STS: target shared memory
    reg decoded_ret;

    // Fetcher
    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .current_pc(current_pc),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .fetcher_state(fetcher_state),
        .instruction(instruction) 
    );

    // Decoder
    decoder decoder_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(instruction),
        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),
        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),
        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_atomic_op(decoded_atomic_op),
        .decoded_barrier(decoded_barrier),
        .decoded_shared(decoded_shared),
        .decoded_ret(decoded_ret)
    );

    // Scheduler
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) scheduler_instance (
        .clk(clk),
        .reset(reset),
        .perf_reset(perf_reset),
        .start(start),
        .thread_count(thread_count),
        .fetcher_state(fetcher_state),
        .core_state(core_state),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_ret(decoded_ret),
        .decoded_barrier(decoded_barrier),
        .lsu_state(lsu_state),
        .current_pc(current_pc),
        .next_pc(next_pc),
        .active_mask(active_mask),
        .perf_cycle_count(perf_cycle_count),
        .perf_instr_count(perf_instr_count),
        .perf_divergence_count(perf_divergence_count),
        .perf_barrier_count(perf_barrier_count),
        .done(done)
    );

    // Dedicated ALU, LSU, registers, & PC unit for each thread this core has capacity for
    // `genvar i; generate for (...)` tells the compiler to instantiate several
    // nearly-identical submodule copies, one per thread lane.
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            // ALU
            alu alu_instance (
                .clk(clk),
                .reset(reset),
                // active_mask[i] gates this lane: it is high only when lane i is
                // valid (within thread_count) AND parked at the block's current
                // (minimum) PC, so diverged/surplus lanes are frozen.
                .enable(active_mask[i]),
                .core_state(core_state),
                .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
                .decoded_alu_output_mux(decoded_alu_output_mux),
                .rs(rs[i]),
                .rt(rt[i]),
                .alu_out(alu_out[i])
            );

            // LSU
            lsu lsu_instance (
                .clk(clk),
                .reset(reset),
                .enable(active_mask[i]),
                .core_state(core_state),
                .decoded_mem_read_enable(decoded_mem_read_enable),
                .decoded_mem_write_enable(decoded_mem_write_enable),
                .decoded_atomic_op(decoded_atomic_op),
                .decoded_shared(decoded_shared),
                .mem_read_valid(data_mem_read_valid[i]),
                .mem_read_address(data_mem_read_address[i]),
                .mem_read_ready(data_mem_read_ready[i]),
                .mem_read_data(data_mem_read_data[i]),
                .mem_write_valid(data_mem_write_valid[i]),
                .mem_write_address(data_mem_write_address[i]),
                .mem_write_data(data_mem_write_data[i]),
                .mem_write_ready(data_mem_write_ready[i]),
                .consumer_atomic(data_mem_atomic[i]),
                // Per-block shared-memory port set (LDS/STS).
                .shared_read_valid(shared_read_valid[i]),
                .shared_read_address(shared_read_address[i]),
                .shared_read_ready(shared_read_ready[i]),
                .shared_read_data(shared_read_data[i]),
                .shared_write_valid(shared_write_valid[i]),
                .shared_write_address(shared_write_address[i]),
                .shared_write_data(shared_write_data[i]),
                .shared_write_ready(shared_write_ready[i]),
                .rs(rs[i]),
                .rt(rt[i]),
                .lsu_state(lsu_state[i]),
                .lsu_out(lsu_out[i])
            );

            // Register File
            registers #(
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREAD_ID(i),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) register_instance (
                .clk(clk),
                .reset(reset),
                .enable(active_mask[i]),
                .block_id(block_id),
                .core_state(core_state),
                .decoded_reg_write_enable(decoded_reg_write_enable),
                .decoded_reg_input_mux(decoded_reg_input_mux),
                .decoded_rd_address(decoded_rd_address),
                .decoded_rs_address(decoded_rs_address),
                .decoded_rt_address(decoded_rt_address),
                .decoded_immediate(decoded_immediate),
                .alu_out(alu_out[i]),
                .lsu_out(lsu_out[i]),
                .rs(rs[i]),
                .rt(rt[i])
            );

            // Program Counter
            pc #(
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
            ) pc_instance (
                .clk(clk),
                .reset(reset),
                .enable(active_mask[i]),
                .core_state(core_state),
                .decoded_nzp(decoded_nzp),
                .decoded_immediate(decoded_immediate),
                .decoded_nzp_write_enable(decoded_nzp_write_enable),
                .decoded_pc_mux(decoded_pc_mux),
                .alu_out(alu_out[i]),
                .current_pc(current_pc),
                .next_pc(next_pc[i])
            );
            // Note on SIMT control flow: each lane computes its own `next_pc`.
            // The scheduler tracks a per-lane `thread_pc` and uses min-PC
            // reconvergence to drive `active_mask`, so lanes that branch to
            // different targets diverge and later reconverge automatically.
        end
    endgenerate

    // Per-block shared memory: a banked on-chip scratchpad shared by every lane
    // in this core/block. LDS/STS route here via each LSU's shared_* ports. The
    // bank-conflict serialisation is absorbed by the scheduler's WAIT state,
    // which holds the core until every lane's LSU leaves REQUESTING/WAITING.
    shared_memory #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_BANKS(THREADS_PER_BLOCK),
        .BANK_SIZE(1 << (DATA_MEM_ADDR_BITS - $clog2(THREADS_PER_BLOCK))),
        .NUM_PORTS(THREADS_PER_BLOCK)
    ) shared_memory_instance (
        .clk(clk),
        .reset(reset),
        .read_valid(shared_read_valid),
        .read_addr(shared_read_address),
        .read_ready(shared_read_ready),
        .read_data(shared_read_data),
        .write_valid(shared_write_valid),
        .write_addr(shared_write_address),
        .write_data(shared_write_data),
        .write_ready(shared_write_ready),
        .bank_conflict(shared_bank_conflict)
    );
endmodule
