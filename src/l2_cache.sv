`default_nettype none
`timescale 1ns/1ns

// L2 DATA CACHE (banked, write-through, snoop-invalidate)
// > Sits between the data memory controller's channel ports and external
//   global memory - one cache bank per memory channel.
// > Read hits are served on-chip; only misses consume external bandwidth.
// > Writes are WRITE-THROUGH (forwarded to external memory and acknowledged
//   only after the external ack), so external memory always holds the
//   authoritative data - the testbench memory models, end-of-kernel results,
//   and the controller's atomic address locks all stay correct unchanged.
// > Coherence: because the controller assigns requests to any free channel,
//   the same address may get cached in several banks. Every completed write
//   therefore SNOOPS the peer banks and invalidates their matching lines
//   (write-update on the writing bank, write-invalidate on the others) -
//   the classic write-through snooping protocol of multi-bank caches.
// > No-allocate on write miss: a streaming store does not evict hot read data.
//
// Timing note: against the testbench's zero-latency external memory model a
// hit costs about the same handful of cycles as a miss - the architectural
// win asserted by test/test_l2_cache_e2e.py is EXTERNAL BANDWIDTH: only cold
// misses reach the external pins (32 loads -> 4 external reads there), and
// banks are shared across cores, so one core's fill serves the other's reuse.
module l2_cache #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8,
    parameter NUM_CHANNELS = 4,
    parameter LINES_PER_BANK = 16
) (
    input wire clk,
    input wire reset,

    // Upstream: the data memory controller's memory-side channel ports.
    input  wire [NUM_CHANNELS-1:0] up_read_valid,
    input  wire [ADDR_BITS-1:0] up_read_address [NUM_CHANNELS-1:0],
    output reg  [NUM_CHANNELS-1:0] up_read_ready,
    output reg  [DATA_BITS-1:0] up_read_data [NUM_CHANNELS-1:0],
    input  wire [NUM_CHANNELS-1:0] up_write_valid,
    input  wire [ADDR_BITS-1:0] up_write_address [NUM_CHANNELS-1:0],
    input  wire [DATA_BITS-1:0] up_write_data [NUM_CHANNELS-1:0],
    output reg  [NUM_CHANNELS-1:0] up_write_ready,

    // Downstream: external global data memory.
    output reg  [NUM_CHANNELS-1:0] mem_read_valid,
    output reg  [ADDR_BITS-1:0] mem_read_address [NUM_CHANNELS-1:0],
    input  wire [NUM_CHANNELS-1:0] mem_read_ready,
    input  wire [DATA_BITS-1:0] mem_read_data [NUM_CHANNELS-1:0],
    output reg  [NUM_CHANNELS-1:0] mem_write_valid,
    output reg  [ADDR_BITS-1:0] mem_write_address [NUM_CHANNELS-1:0],
    output reg  [DATA_BITS-1:0] mem_write_data [NUM_CHANNELS-1:0],
    input  wire [NUM_CHANNELS-1:0] mem_write_ready,

    // Aggregated effectiveness counters (summed over banks; reads only -
    // every write goes external by construction, so counting them would
    // say nothing about the cache).
    output reg [31:0] l2_hit_count,
    output reg [31:0] l2_miss_count
);
    localparam INDEX_BITS = $clog2(LINES_PER_BANK);
    localparam TAG_BITS = ADDR_BITS - INDEX_BITS;

    // Per-bank FSM. Ready pulses last exactly one cycle, then a DRAIN state
    // waits for the controller to drop its (registered) valid so a stale
    // ready can never be mistaken for the ack of a *new* request.
    localparam IDLE    = 3'b000,
        RMISS   = 3'b010,  // external read in flight (line fill)
        WEXT    = 3'b011,  // external write-through in flight
        DRAIN_R = 3'b101,  // ready pulse done; wait for up_read_valid to drop
        DRAIN_W = 3'b110;  // ready pulse done; wait for up_write_valid to drop

    reg [2:0] bank_state [NUM_CHANNELS-1:0];

    // Bank storage, flattened to 1-D unpacked arrays (sv2v/iverilog-safe):
    // element (bank b, line l) lives at index b*LINES_PER_BANK + l.
    reg [DATA_BITS-1:0] line_data  [NUM_CHANNELS*LINES_PER_BANK-1:0];
    reg [TAG_BITS-1:0]  line_tag   [NUM_CHANNELS*LINES_PER_BANK-1:0];
    reg                 line_valid [NUM_CHANNELS*LINES_PER_BANK-1:0];

    // Latched request per bank (address held for fill/write-through/snoop).
    reg [ADDR_BITS-1:0] pending_addr [NUM_CHANNELS-1:0];
    reg [DATA_BITS-1:0] pending_data [NUM_CHANNELS-1:0];

    integer b, j, k;

    always @(posedge clk) begin
        if (reset) begin
            up_read_ready <= {NUM_CHANNELS{1'b0}};
            up_write_ready <= {NUM_CHANNELS{1'b0}};
            mem_read_valid <= {NUM_CHANNELS{1'b0}};
            mem_write_valid <= {NUM_CHANNELS{1'b0}};
            l2_hit_count <= 32'b0;
            l2_miss_count <= 32'b0;
            for (k = 0; k < NUM_CHANNELS; k = k + 1) begin
                bank_state[k] <= IDLE;
                up_read_data[k] <= {DATA_BITS{1'b0}};
                mem_read_address[k] <= {ADDR_BITS{1'b0}};
                mem_write_address[k] <= {ADDR_BITS{1'b0}};
                mem_write_data[k] <= {DATA_BITS{1'b0}};
                pending_addr[k] <= {ADDR_BITS{1'b0}};
                pending_data[k] <= {DATA_BITS{1'b0}};
            end
            for (k = 0; k < NUM_CHANNELS*LINES_PER_BANK; k = k + 1) begin
                line_valid[k] <= 1'b0;
                line_tag[k] <= {TAG_BITS{1'b0}};
                line_data[k] <= {DATA_BITS{1'b0}};
            end
        end else begin
            // Per-cycle counter increments accumulate in blocking locals so
            // several banks hitting/missing in the SAME cycle all count
            // (NBA read-modify-write per bank would collapse to +1).
            reg [31:0] hits_now;
            reg [31:0] misses_now;
            hits_now = 32'b0;
            misses_now = 32'b0;

            // ---- Per-bank FSMs -------------------------------------------
            for (b = 0; b < NUM_CHANNELS; b = b + 1) begin
                // Slot of the line addressed by this bank's *incoming* request
                // and by its *latched* pending request.
                logic [INDEX_BITS-1:0] req_index;
                logic [TAG_BITS-1:0]  req_tag;
                logic [31:0] req_slot;
                logic [31:0] pend_slot;
                req_index = up_read_valid[b] ? up_read_address[b][INDEX_BITS-1:0]
                                             : up_write_address[b][INDEX_BITS-1:0];
                req_tag   = up_read_valid[b] ? up_read_address[b][ADDR_BITS-1:INDEX_BITS]
                                             : up_write_address[b][ADDR_BITS-1:INDEX_BITS];
                req_slot  = b * LINES_PER_BANK + {{(32-INDEX_BITS){1'b0}}, req_index};
                pend_slot = b * LINES_PER_BANK
                            + {{(32-INDEX_BITS){1'b0}}, pending_addr[b][INDEX_BITS-1:0]};

                unique case (bank_state[b])
                    IDLE: begin
                        up_read_ready[b] <= 1'b0;
                        up_write_ready[b] <= 1'b0;
                        if (up_read_valid[b]) begin
                            pending_addr[b] <= up_read_address[b];
                            if (line_valid[req_slot] && line_tag[req_slot] == req_tag) begin
                                // Read hit: single-cycle ready pulse with data.
                                up_read_data[b] <= line_data[req_slot];
                                up_read_ready[b] <= 1'b1;
                                hits_now = hits_now + 1;
                                bank_state[b] <= DRAIN_R;
                            end else begin
                                // Read miss: fill from external memory.
                                mem_read_valid[b] <= 1'b1;
                                mem_read_address[b] <= up_read_address[b];
                                misses_now = misses_now + 1;
                                bank_state[b] <= RMISS;
                            end
                        end else if (up_write_valid[b]) begin
                            // Write-through: always forward to external memory.
                            pending_addr[b] <= up_write_address[b];
                            pending_data[b] <= up_write_data[b];
                            mem_write_valid[b] <= 1'b1;
                            mem_write_address[b] <= up_write_address[b];
                            mem_write_data[b] <= up_write_data[b];
                            bank_state[b] <= WEXT;
                        end
                    end
                    RMISS: begin
                        if (mem_read_ready[b]) begin
                            mem_read_valid[b] <= 1'b0;
                            // Fill the line and serve upstream in one pulse.
                            line_data[pend_slot] <= mem_read_data[b];
                            line_tag[pend_slot] <= pending_addr[b][ADDR_BITS-1:INDEX_BITS];
                            line_valid[pend_slot] <= 1'b1;
                            up_read_data[b] <= mem_read_data[b];
                            up_read_ready[b] <= 1'b1;
                            bank_state[b] <= DRAIN_R;
                        end
                    end
                    DRAIN_R: begin
                        up_read_ready[b] <= 1'b0;
                        if (!up_read_valid[b]) begin
                            bank_state[b] <= IDLE;
                        end
                    end
                    WEXT: begin
                        if (mem_write_ready[b]) begin
                            mem_write_valid[b] <= 1'b0;
                            // Write-update our own bank if the line is
                            // resident (no-allocate on miss)...
                            if (line_valid[pend_slot]
                                && line_tag[pend_slot] == pending_addr[b][ADDR_BITS-1:INDEX_BITS]) begin
                                line_data[pend_slot] <= pending_data[b];
                            end
                            up_write_ready[b] <= 1'b1;
                            bank_state[b] <= DRAIN_W;
                        end
                    end
                    DRAIN_W: begin
                        up_write_ready[b] <= 1'b0;
                        if (!up_write_valid[b]) begin
                            bank_state[b] <= IDLE;
                        end
                    end
                    default: bank_state[b] <= IDLE;
                endcase
            end

            // ---- Snoop-invalidate pass -----------------------------------
            // Runs AFTER the FSM pass so an invalidation always beats a
            // same-cycle fill/update of the same line in a peer bank
            // (conservative: stale data can never survive a write).
            for (b = 0; b < NUM_CHANNELS; b = b + 1) begin
                if (bank_state[b] == WEXT && mem_write_ready[b]) begin
                    for (j = 0; j < NUM_CHANNELS; j = j + 1) begin
                        if (j != b) begin
                            logic [31:0] snoop_slot;
                            snoop_slot = j * LINES_PER_BANK
                                + {{(32-INDEX_BITS){1'b0}}, pending_addr[b][INDEX_BITS-1:0]};
                            if (line_valid[snoop_slot]
                                && line_tag[snoop_slot] == pending_addr[b][ADDR_BITS-1:INDEX_BITS]) begin
                                line_valid[snoop_slot] <= 1'b0;
                            end
                        end
                    end
                end
            end

            l2_hit_count <= l2_hit_count + hits_now;
            l2_miss_count <= l2_miss_count + misses_now;
        end
    end
endmodule
