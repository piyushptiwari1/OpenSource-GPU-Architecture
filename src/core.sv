`default_nettype none
`timescale 1ns/1ns

// COMPUTE CORE (multi-warp SIMT)
// > Handles processing 1 block at a time
// > The block's threads are partitioned into WARPS of THREADS_PER_WARP lanes
// > Each warp has its own front-end (fetcher + icache + decoder) and its own
//   scheduler FSM, so warps execute INDEPENDENTLY and hide each other's
//   memory latency: while warp 0 waits on a load, warp 1 keeps executing.
//   This is the core idea behind "warp scheduling" in real GPUs.
// > Every thread lane still owns a dedicated ALU, LSU, register file and PC
// > With THREADS_PER_WARP == THREADS_PER_BLOCK (the default) there is exactly
//   one warp and the core behaves identically to the classic single-warp
//   design taught by the original tiny-gpu.
//
// Beginner notes:
// 1. This is one of the most rewarding files to re-read in the whole design,
//    because it stitches the shared control path and the per-thread datapath together.
// 2. `fetcher`, `icache`, `decoder`, and `scheduler` are instantiated once per
//    WARP, while `registers`, `alu`, `lsu`, and `pc` are replicated once per
//    thread lane.
// 3. Read declarations like `wire [7:0] next_pc [THREADS_PER_WARP-1:0];` in two parts:
//    each element is 8 bits, and there are `THREADS_PER_WARP` elements in total.
// 4. `generate for (...) begin : warps` is NOT a runtime loop; it tells the
//    synthesizer to replicate the hardware structures inside it at elaboration time.
// 5. If you are new to Verilog, treat this module as a wiring diagram first --
//    follow the signal names to see how submodules connect to each other before
//    trying to reason cycle-by-cycle.
// 6. A block-wide BAR instruction must synchronise ACROSS warps. Each warp's
//    scheduler reports `warp_at_barrier`; the tiny coordinator below releases
//    every warp only once all of them have arrived (or fully retired).
module core #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK = 4,
    // Number of lanes that execute in lockstep under one scheduler. The
    // default (one warp spanning the whole block) preserves the original
    // single-warp behaviour; smaller values create multiple independent
    // warps per block for latency hiding. Must divide THREADS_PER_BLOCK.
    parameter THREADS_PER_WARP = THREADS_PER_BLOCK,
    // L1 instruction cache: direct-mapped lines held per warp slice. The
    // cache is cleared only on a full GPU reset (perf_reset), so it stays
    // warm across the blocks a core processes within one kernel launch.
    parameter ICACHE_LINES = 32,
    // Derived: how many independent warps this core runs concurrently.
    parameter NUM_WARPS = THREADS_PER_BLOCK / THREADS_PER_WARP
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

    // Program Memory (one read channel per warp; driven by each warp's icache)
    output wire [NUM_WARPS-1:0] program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [NUM_WARPS-1:0],
    input [NUM_WARPS-1:0] program_mem_read_ready,
    input [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [NUM_WARPS-1:0],

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

    // Performance counters (summed over this core's warp schedulers).
    output reg [31:0] perf_cycle_count,
    output reg [31:0] perf_instr_count,
    output reg [31:0] perf_divergence_count,
    output reg [31:0] perf_barrier_count,
    // Instruction-cache effectiveness (summed over this core's warp icaches).
    output reg [31:0] perf_icache_hit_count,
    output reg [31:0] perf_icache_miss_count
);
    // Per-block shared memory interface (one banked island shared by ALL lanes
    // of ALL warps). Driven by each lane's LSU when it executes an LDS/STS.
    wire [THREADS_PER_BLOCK-1:0] shared_read_valid;
    wire [7:0] shared_read_address [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] shared_read_ready;
    wire [7:0] shared_read_data [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] shared_write_valid;
    wire [7:0] shared_write_address [THREADS_PER_BLOCK-1:0];
    wire [7:0] shared_write_data [THREADS_PER_BLOCK-1:0];
    wire [THREADS_PER_BLOCK-1:0] shared_write_ready;
    wire [THREADS_PER_BLOCK-1:0] shared_bank_conflict;

    // Per-warp status collected at core scope.
    wire [NUM_WARPS-1:0] warp_done;
    wire [NUM_WARPS-1:0] warp_at_barrier;
    wire [31:0] warp_perf_cycle [NUM_WARPS-1:0];
    wire [31:0] warp_perf_instr [NUM_WARPS-1:0];
    wire [31:0] warp_perf_divergence [NUM_WARPS-1:0];
    wire [31:0] warp_perf_barrier [NUM_WARPS-1:0];
    wire [15:0] warp_icache_hit [NUM_WARPS-1:0];
    wire [15:0] warp_icache_miss [NUM_WARPS-1:0];

    // Block-level barrier coordinator: a BAR may only complete once every
    // warp of the block has arrived at it (fully-retired warps no longer
    // participate). With NUM_WARPS == 1 this collapses to
    // `barrier_release = warp_at_barrier[0]`, the classic single-warp rule.
    wire barrier_release = &(warp_at_barrier | warp_done);

    // The block is done once every warp has retired all of its lanes.
    assign done = &warp_done;

    // Warp slices: an independent front-end + control FSM per warp, plus the
    // per-lane datapath for the warp's threads.
    genvar w;
    genvar t;
    generate
        for (w = 0; w < NUM_WARPS; w = w + 1) begin : warps
            // ---- Per-warp state ------------------------------------------
            // These signals are shared by every lane of THIS warp only.
            wire [2:0] core_state;
            wire [2:0] fetcher_state;
            wire [15:0] instruction;
            wire [7:0] current_pc;
            wire [7:0] next_pc [THREADS_PER_WARP-1:0];
            // Per-lane execution mask produced by the scheduler's min-PC
            // reconvergence: active_mask[t] is high only for lanes that
            // should execute this step.
            wire [THREADS_PER_WARP-1:0] active_mask;
            wire [7:0] rs [THREADS_PER_WARP-1:0];
            wire [7:0] rt [THREADS_PER_WARP-1:0];
            wire [1:0] lsu_state [THREADS_PER_WARP-1:0];
            wire [7:0] lsu_out [THREADS_PER_WARP-1:0];
            wire [7:0] alu_out [THREADS_PER_WARP-1:0];

            // Decoded Instruction Signals (latched per warp by its decoder)
            wire [3:0] decoded_rd_address;
            wire [3:0] decoded_rs_address;
            wire [3:0] decoded_rt_address;
            wire [2:0] decoded_nzp;
            wire [7:0] decoded_immediate;
            wire decoded_reg_write_enable;
            wire decoded_mem_read_enable;
            wire decoded_mem_write_enable;
            wire decoded_nzp_write_enable;
            wire [1:0] decoded_reg_input_mux;
            wire [1:0] decoded_alu_arithmetic_mux;
            wire decoded_alu_output_mux;
            wire decoded_pc_mux;
            wire decoded_atomic_op;
            wire decoded_barrier;
            wire decoded_shared;
            wire decoded_ret;

            // How many of this warp's lanes are valid for the current block.
            // Lanes [w*THREADS_PER_WARP, w*THREADS_PER_WARP + warp_thread_count)
            // participate; a trailing warp of an undersized block may be empty.
            localparam WARP_LANE_BASE = w * THREADS_PER_WARP;
            wire [$clog2(THREADS_PER_WARP):0] warp_thread_count =
                (thread_count >= WARP_LANE_BASE + THREADS_PER_WARP) ? THREADS_PER_WARP :
                (thread_count > WARP_LANE_BASE) ? (thread_count - WARP_LANE_BASE) : 0;

            // Gate the fetcher while the warp is parked at a cross-warp
            // barrier (active_mask == 0 in FETCH): present IDLE so no fetch
            // is launched at the meaningless min-PC of an all-parked warp.
            wire [2:0] fetcher_core_state = (active_mask == '0) ? 3'b000 : core_state;

            // Fetcher <> L1 instruction cache handshake. The fetcher does not
            // talk to the program memory controller directly; its requests are
            // served by the warp's icache, which only forwards misses upstream.
            wire fetch_req_valid;
            wire [PROGRAM_MEM_ADDR_BITS-1:0] fetch_req_address;
            wire fetch_req_ready;
            wire [PROGRAM_MEM_DATA_BITS-1:0] fetch_req_data;
            wire icache_hit;

            // Fetcher (speculative next-line prefetch, static BTFN prediction)
            fetcher #(
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
            ) fetcher_instance (
                .clk(clk),
                .reset(reset),
                .core_state(fetcher_core_state),
                .current_pc(current_pc),
                .mem_read_valid(fetch_req_valid),
                .mem_read_address(fetch_req_address),
                .mem_read_ready(fetch_req_ready),
                .mem_read_data(fetch_req_data),
                .fetcher_state(fetcher_state),
                .instruction(instruction)
            );

            // L1 Instruction Cache (direct-mapped, read-only)
            // > Serves repeated fetches (loops!) without spending
            //   program-memory bandwidth; only misses go upstream.
            // > Reset by perf_reset, not the per-block reset, so the cache
            //   stays warm across all blocks of a kernel launch (program
            //   memory is immutable while a kernel runs).
            icache #(
                .CACHE_LINES(ICACHE_LINES),
                .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .INDEX_BITS($clog2(ICACHE_LINES)),
                .TAG_BITS(PROGRAM_MEM_ADDR_BITS - $clog2(ICACHE_LINES))
            ) icache_instance (
                .clk(clk),
                .reset(perf_reset),
                .enable(1'b1),
                .read_request(fetch_req_valid),
                .address(fetch_req_address),
                .read_ready(fetch_req_ready),
                .read_data(fetch_req_data),
                .cache_hit_out(icache_hit),
                .mem_read_valid(program_mem_read_valid[w]),
                .mem_read_address(program_mem_read_address[w]),
                .mem_read_ready(program_mem_read_ready[w]),
                .mem_read_data(program_mem_read_data[w]),
                .hit_count(warp_icache_hit[w]),
                .miss_count(warp_icache_miss[w])
            );

            // Decoder (one per warp: warps sit at different instructions)
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

            // Scheduler (per warp: min-PC reconvergence over this warp's lanes)
            scheduler #(
                .THREADS_PER_BLOCK(THREADS_PER_WARP)
            ) scheduler_instance (
                .clk(clk),
                .reset(reset),
                .perf_reset(perf_reset),
                .start(start),
                .thread_count(warp_thread_count),
                .fetcher_state(fetcher_state),
                .core_state(core_state),
                .decoded_mem_read_enable(decoded_mem_read_enable),
                .decoded_mem_write_enable(decoded_mem_write_enable),
                .decoded_ret(decoded_ret),
                .decoded_barrier(decoded_barrier),
                .barrier_release(barrier_release),
                .warp_at_barrier(warp_at_barrier[w]),
                .lsu_state(lsu_state),
                .current_pc(current_pc),
                .next_pc(next_pc),
                .active_mask(active_mask),
                .perf_cycle_count(warp_perf_cycle[w]),
                .perf_instr_count(warp_perf_instr[w]),
                .perf_divergence_count(warp_perf_divergence[w]),
                .perf_barrier_count(warp_perf_barrier[w]),
                .done(warp_done[w])
            );

            // Dedicated ALU, LSU, registers, & PC unit for each of this warp's
            // thread lanes. Lane t of warp w is global lane WARP_LANE_BASE + t
            // in the block; that global index selects its data-memory channel,
            // shared-memory port, and %threadIdx value.
            for (t = 0; t < THREADS_PER_WARP; t = t + 1) begin : threads
                localparam GLOBAL_LANE = WARP_LANE_BASE + t;

                // ALU
                alu alu_instance (
                    .clk(clk),
                    .reset(reset),
                    // active_mask[t] gates this lane: it is high only when the
                    // lane is valid (within warp_thread_count) AND parked at
                    // the warp's current (minimum) PC, so diverged/surplus
                    // lanes are frozen.
                    .enable(active_mask[t]),
                    .core_state(core_state),
                    .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
                    .decoded_alu_output_mux(decoded_alu_output_mux),
                    .rs(rs[t]),
                    .rt(rt[t]),
                    .alu_out(alu_out[t])
                );

                // LSU
                lsu lsu_instance (
                    .clk(clk),
                    .reset(reset),
                    .enable(active_mask[t]),
                    .core_state(core_state),
                    .decoded_mem_read_enable(decoded_mem_read_enable),
                    .decoded_mem_write_enable(decoded_mem_write_enable),
                    .decoded_atomic_op(decoded_atomic_op),
                    .decoded_shared(decoded_shared),
                    .mem_read_valid(data_mem_read_valid[GLOBAL_LANE]),
                    .mem_read_address(data_mem_read_address[GLOBAL_LANE]),
                    .mem_read_ready(data_mem_read_ready[GLOBAL_LANE]),
                    .mem_read_data(data_mem_read_data[GLOBAL_LANE]),
                    .mem_write_valid(data_mem_write_valid[GLOBAL_LANE]),
                    .mem_write_address(data_mem_write_address[GLOBAL_LANE]),
                    .mem_write_data(data_mem_write_data[GLOBAL_LANE]),
                    .mem_write_ready(data_mem_write_ready[GLOBAL_LANE]),
                    .consumer_atomic(data_mem_atomic[GLOBAL_LANE]),
                    // Per-block shared-memory port set (LDS/STS).
                    .shared_read_valid(shared_read_valid[GLOBAL_LANE]),
                    .shared_read_address(shared_read_address[GLOBAL_LANE]),
                    .shared_read_ready(shared_read_ready[GLOBAL_LANE]),
                    .shared_read_data(shared_read_data[GLOBAL_LANE]),
                    .shared_write_valid(shared_write_valid[GLOBAL_LANE]),
                    .shared_write_address(shared_write_address[GLOBAL_LANE]),
                    .shared_write_data(shared_write_data[GLOBAL_LANE]),
                    .shared_write_ready(shared_write_ready[GLOBAL_LANE]),
                    .rs(rs[t]),
                    .rt(rt[t]),
                    .lsu_state(lsu_state[t]),
                    .lsu_out(lsu_out[t])
                );

                // Register File (%blockDim stays the BLOCK size; %threadIdx is
                // the lane's global index within the block)
                registers #(
                    .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                    .THREAD_ID(GLOBAL_LANE),
                    .DATA_BITS(DATA_MEM_DATA_BITS)
                ) register_instance (
                    .clk(clk),
                    .reset(reset),
                    .enable(active_mask[t]),
                    .block_id(block_id),
                    .core_state(core_state),
                    .decoded_reg_write_enable(decoded_reg_write_enable),
                    .decoded_reg_input_mux(decoded_reg_input_mux),
                    .decoded_rd_address(decoded_rd_address),
                    .decoded_rs_address(decoded_rs_address),
                    .decoded_rt_address(decoded_rt_address),
                    .decoded_immediate(decoded_immediate),
                    .alu_out(alu_out[t]),
                    .lsu_out(lsu_out[t]),
                    .rs(rs[t]),
                    .rt(rt[t])
                );

                // Program Counter
                pc #(
                    .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                    .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
                ) pc_instance (
                    .clk(clk),
                    .reset(reset),
                    .enable(active_mask[t]),
                    .core_state(core_state),
                    .decoded_nzp(decoded_nzp),
                    .decoded_immediate(decoded_immediate),
                    .decoded_nzp_write_enable(decoded_nzp_write_enable),
                    .decoded_pc_mux(decoded_pc_mux),
                    .alu_out(alu_out[t]),
                    .current_pc(current_pc),
                    .next_pc(next_pc[t])
                );
                // Note on SIMT control flow: each lane computes its own
                // `next_pc`. The scheduler tracks a per-lane `thread_pc` and
                // uses min-PC reconvergence to drive `active_mask`, so lanes
                // that branch to different targets diverge and later
                // reconverge automatically -- within their warp. Lanes in
                // DIFFERENT warps never constrain each other's PC.
            end
        end
    endgenerate

    // Aggregate the per-warp performance counters into the core's outputs.
    // Registered (rather than combinational) because Icarus does not build a
    // reliable @(*) sensitivity list over unpacked-array element reads.
    integer pw;
    reg [31:0] sum_cycle, sum_instr, sum_diverge, sum_barrier;
    reg [31:0] sum_icache_hit, sum_icache_miss;
    always @(posedge clk) begin
        if (perf_reset) begin
            perf_cycle_count <= 32'b0;
            perf_instr_count <= 32'b0;
            perf_divergence_count <= 32'b0;
            perf_barrier_count <= 32'b0;
            perf_icache_hit_count <= 32'b0;
            perf_icache_miss_count <= 32'b0;
        end else begin
            sum_cycle = 32'b0;
            sum_instr = 32'b0;
            sum_diverge = 32'b0;
            sum_barrier = 32'b0;
            sum_icache_hit = 32'b0;
            sum_icache_miss = 32'b0;
            for (pw = 0; pw < NUM_WARPS; pw = pw + 1) begin
                sum_cycle = sum_cycle + warp_perf_cycle[pw];
                sum_instr = sum_instr + warp_perf_instr[pw];
                sum_diverge = sum_diverge + warp_perf_divergence[pw];
                sum_barrier = sum_barrier + warp_perf_barrier[pw];
                sum_icache_hit = sum_icache_hit + {16'b0, warp_icache_hit[pw]};
                sum_icache_miss = sum_icache_miss + {16'b0, warp_icache_miss[pw]};
            end
            perf_cycle_count <= sum_cycle;
            perf_instr_count <= sum_instr;
            perf_divergence_count <= sum_diverge;
            perf_barrier_count <= sum_barrier;
            perf_icache_hit_count <= sum_icache_hit;
            perf_icache_miss_count <= sum_icache_miss;
        end
    end

    // Per-block shared memory: a banked on-chip scratchpad shared by every lane
    // of every warp in this core/block. LDS/STS route here via each LSU's
    // shared_* ports. Bank-conflict serialisation is absorbed by each warp
    // scheduler's WAIT state, which holds that warp until every one of its
    // lanes' LSUs leaves REQUESTING/WAITING. Cross-warp port contention is
    // resolved by the island's own per-bank arbitration.
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
