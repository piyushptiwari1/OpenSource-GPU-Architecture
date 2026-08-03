`default_nettype none
`timescale 1ns/1ns

// GPU
// > Built to use an external async memory with multi-channel read/write
// > Assumes that the program is loaded into program memory, data into data memory, and threads into
//   the device control register before the start signal is triggered
// > Has memory controllers to interface between external memory and its multiple cores
// > Configurable number of cores and thread capacity per core
module gpu #(
    parameter DATA_MEM_ADDR_BITS = 8,        // Number of bits in data memory address (256 rows)
    parameter DATA_MEM_DATA_BITS = 8,        // Number of bits in data memory value (8 bit data)
    parameter DATA_MEM_NUM_CHANNELS = 4,     // Number of concurrent channels for sending requests to data memory
    parameter PROGRAM_MEM_ADDR_BITS = 8,     // Number of bits in program memory address (256 rows)
    parameter PROGRAM_MEM_DATA_BITS = 16,    // Number of bits in program memory value (16 bit instruction)
    parameter PROGRAM_MEM_NUM_CHANNELS = 1,  // Number of concurrent channels for sending requests to program memory
    parameter NUM_CORES = 2,                 // Number of cores to include in this GPU
    parameter THREADS_PER_BLOCK = 4,         // Number of threads to handle per block (determines the compute resources of each core)
    // Number of lanes that execute in lockstep under one warp scheduler.
    // The default (whole block = one warp) preserves the classic single-warp
    // behaviour; smaller values split each block into multiple independent
    // warps that hide each other's memory latency (real-GPU warp scheduling).
    // Must divide THREADS_PER_BLOCK.
    parameter THREADS_PER_WARP = THREADS_PER_BLOCK
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Device Control Register
    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // Program Memory
    output wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS-1:0],
    input wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS-1:0],

    // Data Memory
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS-1:0],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready,
    input wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS-1:0],
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS-1:0],
    output wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS-1:0],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready,

    // Performance counters, aggregated (summed) across all cores. Exposed at the
    // top level so a testbench can observe SIMT execution behaviour.
    output reg [31:0] perf_cycle_count,
    output reg [31:0] perf_instr_count,
    output reg [31:0] perf_divergence_count,
    output reg [31:0] perf_barrier_count,
    // Total memory read requests eliminated by warp-level coalescing (summed
    // across all cores). A value of 0 means no two lanes shared a load address.
    output reg [31:0] perf_coalesced_count,
    // L1 instruction cache effectiveness, aggregated (summed) across all cores.
    output reg [31:0] perf_icache_hit_count,
    output reg [31:0] perf_icache_miss_count,
    // L2 data cache effectiveness (banked cache between the data memory
    // controller and external memory; read hits stay on-chip).
    output wire [31:0] perf_l2_hit_count,
    output wire [31:0] perf_l2_miss_count,
    // Posted (scoreboarded) memory operations, aggregated across all cores.
    // Each posted op overlapped its memory latency with continued execution.
    output reg [31:0] perf_posted_count,

    // Fixed-function rasterizer command interface (host-driven, like the
    // DCR: the host submits one primitive at a time, exactly how pre-shader
    // GPUs took point/line/rect/triangle commands). Rendered pixels are
    // written into the framebuffer window of data memory through the same
    // memory controller + write-through L2 as the SIMT lanes' stores, so
    // kernels can read rendered output back with plain LDRs, coherently.
    input wire raster_cmd_valid,
    input wire [2:0] raster_cmd_op,           // 001=POINT 010=LINE 011=RECT 100=TRIANGLE
    input wire [7:0] raster_x0,
    input wire [7:0] raster_y0,
    input wire [7:0] raster_x1,
    input wire [7:0] raster_y1,
    input wire [7:0] raster_x2,
    input wire [7:0] raster_y2,
    input wire [7:0] raster_color,
    output wire raster_cmd_ready,
    // Busy covers the full path: primitive walk AND every pixel write
    // committed to memory. Poll !raster_busy before reading the frame.
    output wire raster_busy,
    output wire raster_done
);
    // Control
    wire [7:0] thread_count;

    // Compute Core State
    reg [NUM_CORES-1:0] core_start;
    reg [NUM_CORES-1:0] core_reset;
    reg [NUM_CORES-1:0] core_done;
    reg [7:0] core_block_id [NUM_CORES-1:0];
    reg [$clog2(THREADS_PER_BLOCK):0] core_thread_count [NUM_CORES-1:0];

    // LSU <> Data Memory Controller Channels
    localparam NUM_LSUS = NUM_CORES * THREADS_PER_BLOCK;
    // The data memory controller serves the SIMT lanes' LSUs plus one extra
    // consumer: the fixed-function raster writer.
    localparam NUM_DMEM_CONSUMERS = NUM_LSUS + 1;
    reg [NUM_LSUS-1:0] lsu_read_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] lsu_read_address [NUM_LSUS-1:0];
    wire [NUM_LSUS-1:0] lsu_read_ready;
    wire [DATA_MEM_DATA_BITS-1:0] lsu_read_data [NUM_LSUS-1:0];
    reg [NUM_LSUS-1:0] lsu_write_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] lsu_write_address [NUM_LSUS-1:0];
    reg [DATA_MEM_DATA_BITS-1:0] lsu_write_data [NUM_LSUS-1:0];
    wire [NUM_LSUS-1:0] lsu_write_ready;
    wire [NUM_LSUS-1:0] lsu_atomic;

    // Combined consumer arrays presented to the data memory controller:
    // slots [0, NUM_LSUS) are the lanes, slot NUM_LSUS is the raster writer.
    wire [NUM_DMEM_CONSUMERS-1:0] dmem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] dmem_read_address [NUM_DMEM_CONSUMERS-1:0];
    wire [NUM_DMEM_CONSUMERS-1:0] dmem_read_ready;
    wire [DATA_MEM_DATA_BITS-1:0] dmem_read_data [NUM_DMEM_CONSUMERS-1:0];
    wire [NUM_DMEM_CONSUMERS-1:0] dmem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] dmem_write_address [NUM_DMEM_CONSUMERS-1:0];
    wire [DATA_MEM_DATA_BITS-1:0] dmem_write_data [NUM_DMEM_CONSUMERS-1:0];
    wire [NUM_DMEM_CONSUMERS-1:0] dmem_write_ready;
    wire [NUM_DMEM_CONSUMERS-1:0] dmem_atomic;

    // Raster writer's memory port and pixel-stream wires.
    wire rop_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] rop_write_address;
    wire [DATA_MEM_DATA_BITS-1:0] rop_write_data;
    wire raster_pixel_valid;
    wire [7:0] raster_pixel_x;
    wire [7:0] raster_pixel_y;
    wire [7:0] raster_pixel_color;
    wire raster_pixel_ack;
    wire raster_unit_busy;
    wire raster_writer_busy;

    // Fetcher <> Program Memory Controller Channels (one per warp per core)
    localparam WARPS_PER_CORE = THREADS_PER_BLOCK / THREADS_PER_WARP;
    localparam NUM_FETCHERS = NUM_CORES * WARPS_PER_CORE;
    wire [NUM_FETCHERS-1:0] fetcher_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] fetcher_read_address [NUM_FETCHERS-1:0];
    wire [NUM_FETCHERS-1:0] fetcher_read_ready;
    wire [PROGRAM_MEM_DATA_BITS-1:0] fetcher_read_data [NUM_FETCHERS-1:0];

    // Per-core performance counters (aggregated below into the top-level ports).
    wire [31:0] core_perf_cycle_count [NUM_CORES-1:0];
    wire [31:0] core_perf_instr_count [NUM_CORES-1:0];
    wire [31:0] core_perf_divergence_count [NUM_CORES-1:0];
    wire [31:0] core_perf_barrier_count [NUM_CORES-1:0];
    // Per-core count of memory read requests eliminated by warp coalescing.
    wire [31:0] core_coalesced_total [NUM_CORES-1:0];
    // Per-core L1 instruction-cache hit/miss counts (summed over warps).
    wire [31:0] core_icache_hit_count [NUM_CORES-1:0];
    wire [31:0] core_icache_miss_count [NUM_CORES-1:0];
    // Per-core posted (scoreboarded) memory-op counts.
    wire [31:0] core_posted_count [NUM_CORES-1:0];

    // Controller <> L2 data cache channel wires. The data memory controller's
    // memory-side ports no longer reach the external pins directly; the
    // banked write-through L2 sits in between and forwards only misses
    // (reads) / write-throughs (writes) to external memory.
    wire [DATA_MEM_NUM_CHANNELS-1:0] l2_up_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] l2_up_read_address [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] l2_up_read_ready;
    wire [DATA_MEM_DATA_BITS-1:0] l2_up_read_data [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] l2_up_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] l2_up_write_address [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_DATA_BITS-1:0] l2_up_write_data [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] l2_up_write_ready;
    
    initial begin
        $dumpfile("gpu.vcd");
        $dumpvars(0, gpu);
    end

    // Device Control Register
    dcr dcr_instance (
        .clk(clk),
        .reset(reset),

        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

    // Data Memory Controller
    controller #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_DMEM_CONSUMERS),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_memory_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(dmem_read_valid),
        .consumer_read_address(dmem_read_address),
        .consumer_read_ready(dmem_read_ready),
        .consumer_read_data(dmem_read_data),
        .consumer_write_valid(dmem_write_valid),
        .consumer_write_address(dmem_write_address),
        .consumer_write_data(dmem_write_data),
        .consumer_write_ready(dmem_write_ready),
        .consumer_atomic(dmem_atomic),

        .mem_read_valid(l2_up_read_valid),
        .mem_read_address(l2_up_read_address),
        .mem_read_ready(l2_up_read_ready),
        .mem_read_data(l2_up_read_data),
        .mem_write_valid(l2_up_write_valid),
        .mem_write_address(l2_up_write_address),
        .mem_write_data(l2_up_write_data),
        .mem_write_ready(l2_up_write_ready)
    );

    // ---- Consumer bridge: SIMT lanes + raster writer -> controller -------
    // Slots [0, NUM_LSUS) carry the lanes' LSU traffic unchanged; slot
    // NUM_LSUS is the raster writer (write-only; its read side is tied off,
    // and it never participates in atomics).
    genvar dc;
    generate
        for (dc = 0; dc < NUM_LSUS; dc = dc + 1) begin : dmem_bridge
            assign dmem_read_valid[dc] = lsu_read_valid[dc];
            assign dmem_read_address[dc] = lsu_read_address[dc];
            assign dmem_write_valid[dc] = lsu_write_valid[dc];
            assign dmem_write_address[dc] = lsu_write_address[dc];
            assign dmem_write_data[dc] = lsu_write_data[dc];
            assign dmem_atomic[dc] = lsu_atomic[dc];
            assign lsu_read_ready[dc] = dmem_read_ready[dc];
            assign lsu_read_data[dc] = dmem_read_data[dc];
            assign lsu_write_ready[dc] = dmem_write_ready[dc];
        end
    endgenerate
    assign dmem_read_valid[NUM_LSUS] = 1'b0;
    assign dmem_read_address[NUM_LSUS] = {DATA_MEM_ADDR_BITS{1'b0}};
    assign dmem_write_valid[NUM_LSUS] = rop_write_valid;
    assign dmem_write_address[NUM_LSUS] = rop_write_address;
    assign dmem_write_data[NUM_LSUS] = rop_write_data;
    assign dmem_atomic[NUM_LSUS] = 1'b0;

    // ---- Fixed-function graphics path -------------------------------------
    // Host-submitted primitives (point/line/rect/triangle) are walked by the
    // rasterizer; the raster writer streams the covered pixels into the
    // framebuffer window of data memory (FB base 64, 8-pixel row stride)
    // through the shared controller + L2, coherently with the SIMT lanes.
    rasterizer #(
        .COORD_BITS(8),
        .COLOR_BITS(DATA_MEM_DATA_BITS)
    ) rasterizer_instance (
        .clk(clk),
        .reset(reset),
        .cmd_valid(raster_cmd_valid),
        .cmd_op(raster_cmd_op),
        .x0(raster_x0),
        .y0(raster_y0),
        .x1(raster_x1),
        .y1(raster_y1),
        .x2(raster_x2),
        .y2(raster_y2),
        .color(raster_color),
        .cmd_ready(raster_cmd_ready),
        .pixel_valid(raster_pixel_valid),
        .pixel_x(raster_pixel_x),
        .pixel_y(raster_pixel_y),
        .pixel_color(raster_pixel_color),
        .pixel_ack(raster_pixel_ack),
        .busy(raster_unit_busy),
        .done(raster_done)
    );

    raster_writer #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .COORD_BITS(8),
        .FB_BASE(64),
        .FB_WIDTH_LOG2(3)
    ) raster_writer_instance (
        .clk(clk),
        .reset(reset),
        .pixel_valid(raster_pixel_valid),
        .pixel_x(raster_pixel_x),
        .pixel_y(raster_pixel_y),
        .pixel_color(raster_pixel_color),
        .pixel_ack(raster_pixel_ack),
        .mem_write_valid(rop_write_valid),
        .mem_write_address(rop_write_address),
        .mem_write_data(rop_write_data),
        .mem_write_ready(dmem_write_ready[NUM_LSUS]),
        .busy(raster_writer_busy)
    );

    // Busy until the primitive walk finishes AND every pixel write commits.
    assign raster_busy = raster_unit_busy || raster_writer_busy;

    // L2 Data Cache (banked write-through with snoop-invalidate)
    // > One bank per data-memory channel; read hits are served on-chip and
    //   only misses / write-throughs reach the external data memory pins.
    // > Write-through keeps external memory authoritative, so kernel results
    //   remain externally inspectable and the controller's atomic address
    //   locks (which sit upstream of this cache) stay correct.
    l2_cache #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .LINES_PER_BANK(4),
        .WORDS_PER_LINE(4)
    ) l2_cache_instance (
        .clk(clk),
        .reset(reset),

        .up_read_valid(l2_up_read_valid),
        .up_read_address(l2_up_read_address),
        .up_read_ready(l2_up_read_ready),
        .up_read_data(l2_up_read_data),
        .up_write_valid(l2_up_write_valid),
        .up_write_address(l2_up_write_address),
        .up_write_data(l2_up_write_data),
        .up_write_ready(l2_up_write_ready),

        .mem_read_valid(data_mem_read_valid),
        .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready),
        .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid),
        .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data),
        .mem_write_ready(data_mem_write_ready),

        .l2_hit_count(perf_l2_hit_count),
        .l2_miss_count(perf_l2_miss_count)
    );

    // Program Memory Controller
    controller #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_FETCHERS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(0)
    ) program_memory_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(fetcher_read_valid),
        .consumer_read_address(fetcher_read_address),
        .consumer_read_ready(fetcher_read_ready),
        .consumer_read_data(fetcher_read_data),

        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data)
    );

    // Dispatcher
    dispatch #(
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) dispatch_instance (
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

    // Compute Cores
    genvar i;
    generate
        for (i = 0; i < NUM_CORES; i = i + 1) begin : cores
            // EDA: We create separate signals here to pass to cores because of a requirement
            // by the OpenLane EDA flow (uses Verilog 2005) that prevents slicing the top-level signals
            wire [THREADS_PER_BLOCK-1:0] core_lsu_read_valid;
            wire [DATA_MEM_ADDR_BITS-1:0] core_lsu_read_address [THREADS_PER_BLOCK-1:0];
            reg [THREADS_PER_BLOCK-1:0] core_lsu_read_ready;
            reg [DATA_MEM_DATA_BITS-1:0] core_lsu_read_data [THREADS_PER_BLOCK-1:0];
            wire [THREADS_PER_BLOCK-1:0] core_lsu_write_valid;
            wire [DATA_MEM_ADDR_BITS-1:0] core_lsu_write_address [THREADS_PER_BLOCK-1:0];
            wire [DATA_MEM_DATA_BITS-1:0] core_lsu_write_data [THREADS_PER_BLOCK-1:0];
            reg [THREADS_PER_BLOCK-1:0] core_lsu_write_ready;
            wire [THREADS_PER_BLOCK-1:0] core_lsu_atomic;

            // ---- Warp-level same-address read coalescing -------------------
            // When several lanes in this core issue a LOAD to the *identical*
            // address in the same cycle, only the lowest-index lane (the
            // "leader") actually forwards a read request to the memory
            // controller; the other lanes ("followers") are served from the
            // leader's result. This is correct for the single-word memory model
            // here (same address -> same data) and collapses N identical loads
            // into one memory transaction. Lanes with distinct addresses (e.g.
            // matadd/matmul) form singleton groups and behave exactly as before.
            // Atomic accesses NEVER coalesce (each keeps its own locked RMW).
            reg  [THREADS_PER_BLOCK-1:0] read_is_leader;
            // For each lane, the index of the leader serving its address.
            reg  [$clog2(THREADS_PER_BLOCK):0] read_leader_idx [THREADS_PER_BLOCK-1:0];
            integer cl_a, cl_b;
            always @(*) begin
                for (cl_a = 0; cl_a < THREADS_PER_BLOCK; cl_a = cl_a + 1) begin
                    // Default: a lane leads itself (also the case for atomics
                    // and for lanes not issuing a read).
                    read_is_leader[cl_a] = core_lsu_read_valid[cl_a];
                    read_leader_idx[cl_a] = cl_a[$clog2(THREADS_PER_BLOCK):0];
                    if (core_lsu_read_valid[cl_a] && !core_lsu_atomic[cl_a]) begin
                        // Walk every lane; the lowest-index non-atomic lane with
                        // the same address wins as leader (iterate downward so the
                        // final write keeps the smallest matching index).
                        for (cl_b = THREADS_PER_BLOCK - 1; cl_b >= 0; cl_b = cl_b - 1) begin
                            if (core_lsu_read_valid[cl_b] && !core_lsu_atomic[cl_b]
                                && core_lsu_read_address[cl_b] == core_lsu_read_address[cl_a]) begin
                                read_leader_idx[cl_a] = cl_b[$clog2(THREADS_PER_BLOCK):0];
                            end
                        end
                        // This lane is a leader only if it is its own leader.
                        if (read_leader_idx[cl_a] != cl_a[$clog2(THREADS_PER_BLOCK):0]) begin
                            read_is_leader[cl_a] = 1'b0;
                        end
                    end
                end
            end

            // Count of follower read requests eliminated by coalescing in this
            // core, accumulated over the whole run (cleared only on full reset).
            reg [31:0] core_coalesced_count;
            reg [THREADS_PER_BLOCK-1:0] prev_read_valid;

            // Pass through signals between LSUs and data memory controller
            genvar j;
            for (j = 0; j < THREADS_PER_BLOCK; j = j + 1) begin
                localparam lsu_index = i * THREADS_PER_BLOCK + j;
                always @(posedge clk) begin 
                    // Followers do NOT drive a request to the controller; only
                    // the leader's read is forwarded (atomics always lead).
                    lsu_read_valid[lsu_index] <= core_lsu_read_valid[j] && read_is_leader[j];
                    lsu_read_address[lsu_index] <= core_lsu_read_address[j];

                    lsu_write_valid[lsu_index] <= core_lsu_write_valid[j];
                    lsu_write_address[lsu_index] <= core_lsu_write_address[j];
                    lsu_write_data[lsu_index] <= core_lsu_write_data[j];

                    // Each lane takes its read response from its leader's
                    // controller channel; a leader's index is itself.
                    core_lsu_read_ready[j] <= lsu_read_ready[i * THREADS_PER_BLOCK + read_leader_idx[j]];
                    core_lsu_read_data[j] <= lsu_read_data[i * THREADS_PER_BLOCK + read_leader_idx[j]];
                    core_lsu_write_ready[j] <= lsu_write_ready[lsu_index];
                end
                // Atomic flag is combinational from LSU; forward without a
                // pipeline stage so the controller sees it in the same cycle
                // it samples consumer_read_valid.
                assign lsu_atomic[lsu_index] = core_lsu_atomic[j];
            end

            // Coalescing statistics: on the cycle a lane first raises its read
            // request (rising edge of core_lsu_read_valid), if it is a follower
            // its memory access was saved -- count it once.
            integer cc;
            reg [31:0] coalesced_this_cycle;
            always @(posedge clk) begin
                if (reset) begin
                    core_coalesced_count <= 32'b0;
                    prev_read_valid <= {THREADS_PER_BLOCK{1'b0}};
                end else begin
                    coalesced_this_cycle = 32'b0;
                    for (cc = 0; cc < THREADS_PER_BLOCK; cc = cc + 1) begin
                        if (core_lsu_read_valid[cc] && !prev_read_valid[cc]
                            && !read_is_leader[cc]) begin
                            coalesced_this_cycle = coalesced_this_cycle + 1;
                        end
                    end
                    core_coalesced_count <= core_coalesced_count + coalesced_this_cycle;
                    prev_read_valid <= core_lsu_read_valid;
                end
            end
            assign core_coalesced_total[i] = core_coalesced_count;

            // ---- Per-warp program-memory channels --------------------------
            // Each warp slice inside the core owns an independent fetch
            // channel (fetcher + icache); map warp w of core i onto global
            // program-memory consumer i * WARPS_PER_CORE + w.
            wire [WARPS_PER_CORE-1:0] core_prog_read_valid;
            wire [PROGRAM_MEM_ADDR_BITS-1:0] core_prog_read_address [WARPS_PER_CORE-1:0];
            wire [WARPS_PER_CORE-1:0] core_prog_read_ready;
            wire [PROGRAM_MEM_DATA_BITS-1:0] core_prog_read_data [WARPS_PER_CORE-1:0];

            genvar wch;
            for (wch = 0; wch < WARPS_PER_CORE; wch = wch + 1) begin : prog_channels
                assign fetcher_read_valid[i * WARPS_PER_CORE + wch] = core_prog_read_valid[wch];
                assign fetcher_read_address[i * WARPS_PER_CORE + wch] = core_prog_read_address[wch];
                assign core_prog_read_ready[wch] = fetcher_read_ready[i * WARPS_PER_CORE + wch];
                assign core_prog_read_data[wch] = fetcher_read_data[i * WARPS_PER_CORE + wch];
            end

            // Compute Core
            core #(
                .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREADS_PER_WARP(THREADS_PER_WARP)
            ) core_instance (
                .clk(clk),
                .reset(core_reset[i]),
                .perf_reset(reset),
                .start(core_start[i]),
                .done(core_done[i]),
                .block_id(core_block_id[i]),
                .thread_count(core_thread_count[i]),
                
                .program_mem_read_valid(core_prog_read_valid),
                .program_mem_read_address(core_prog_read_address),
                .program_mem_read_ready(core_prog_read_ready),
                .program_mem_read_data(core_prog_read_data),

                .data_mem_read_valid(core_lsu_read_valid),
                .data_mem_read_address(core_lsu_read_address),
                .data_mem_read_ready(core_lsu_read_ready),
                .data_mem_read_data(core_lsu_read_data),
                .data_mem_write_valid(core_lsu_write_valid),
                .data_mem_write_address(core_lsu_write_address),
                .data_mem_write_data(core_lsu_write_data),
                .data_mem_write_ready(core_lsu_write_ready),
                .data_mem_atomic(core_lsu_atomic),

                .perf_cycle_count(core_perf_cycle_count[i]),
                .perf_instr_count(core_perf_instr_count[i]),
                .perf_divergence_count(core_perf_divergence_count[i]),
                .perf_barrier_count(core_perf_barrier_count[i]),
                .perf_posted_count(core_posted_count[i]),
                .perf_icache_hit_count(core_icache_hit_count[i]),
                .perf_icache_miss_count(core_icache_miss_count[i])
            );
        end
    endgenerate

    // Aggregate per-core performance counters into the top-level outputs.
    // Registered (rather than combinational) because Icarus does not build a
    // reliable @(*) sensitivity list over unpacked-array element reads.
    integer c;
    reg [31:0] sum_cycle, sum_instr, sum_diverge, sum_barrier, sum_coalesced;
    reg [31:0] sum_icache_hit, sum_icache_miss, sum_posted;
    always @(posedge clk) begin
        if (reset) begin
            perf_cycle_count <= 32'b0;
            perf_instr_count <= 32'b0;
            perf_divergence_count <= 32'b0;
            perf_barrier_count <= 32'b0;
            perf_coalesced_count <= 32'b0;
            perf_icache_hit_count <= 32'b0;
            perf_icache_miss_count <= 32'b0;
            perf_posted_count <= 32'b0;
        end else begin
            sum_cycle = 32'b0;
            sum_instr = 32'b0;
            sum_diverge = 32'b0;
            sum_barrier = 32'b0;
            sum_coalesced = 32'b0;
            sum_icache_hit = 32'b0;
            sum_icache_miss = 32'b0;
            sum_posted = 32'b0;
            for (c = 0; c < NUM_CORES; c = c + 1) begin
                sum_cycle = sum_cycle + core_perf_cycle_count[c];
                sum_instr = sum_instr + core_perf_instr_count[c];
                sum_diverge = sum_diverge + core_perf_divergence_count[c];
                sum_barrier = sum_barrier + core_perf_barrier_count[c];
                sum_coalesced = sum_coalesced + core_coalesced_total[c];
                sum_icache_hit = sum_icache_hit + core_icache_hit_count[c];
                sum_icache_miss = sum_icache_miss + core_icache_miss_count[c];
                sum_posted = sum_posted + core_posted_count[c];
            end
            perf_cycle_count <= sum_cycle;
            perf_instr_count <= sum_instr;
            perf_divergence_count <= sum_diverge;
            perf_barrier_count <= sum_barrier;
            perf_coalesced_count <= sum_coalesced;
            perf_icache_hit_count <= sum_icache_hit;
            perf_icache_miss_count <= sum_icache_miss;
            perf_posted_count <= sum_posted;
        end
    end
endmodule
