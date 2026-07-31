`default_nettype none
`timescale 1ns/1ns

// L2 DATA CACHE (line-interleaved home banks, burst fills, write-through)
// > Sits between the data memory controller's channel ports and external
//   global memory.
// > MULTI-WORD LINES + BURST FILLS (address-range coalescing): a read miss
//   fetches the whole WORDS_PER_LINE-word line with back-to-back sequential
//   external reads on the bank's channel. A warp touching neighbouring
//   addresses (the classic strided access) costs ONE line transaction
//   instead of one scattered word transaction per lane - the neighbours hit
//   on-chip. Sequential burst beats are also exactly the traffic real DRAM
//   serves cheaply (open-row streaming).
// > HOME BANKS (structural coherence): bank = line_address % NUM_CHANNELS.
//   Every address has exactly one possible cache location, so no snooping
//   is ever needed - a request on any upstream channel is routed to its
//   home bank by a small crossbar/arbiter, and same-line requests
//   serialise at the bank (second one hits the fresh fill).
// > Writes are WRITE-THROUGH (external ack before upstream ack) with
//   update-if-resident and no-allocate on miss: external memory stays
//   authoritative (testbench models and end-of-kernel results unchanged)
//   and the controller's atomic address locks upstream stay correct.
//
// Requires power-of-2 NUM_CHANNELS, LINES_PER_BANK, WORDS_PER_LINE.
// Effectiveness proven by test/test_l2_cache_e2e.py (temporal reuse) and
// test/test_burst_coalescing_e2e.py (spatial locality: 32 loads -> 4 line
// bursts under an open-row external memory model).
module l2_cache #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8,
    parameter NUM_CHANNELS = 4,
    parameter LINES_PER_BANK = 4,
    parameter WORDS_PER_LINE = 4
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

    // Downstream: external global data memory (bank b owns channel b).
    output reg  [NUM_CHANNELS-1:0] mem_read_valid,
    output reg  [ADDR_BITS-1:0] mem_read_address [NUM_CHANNELS-1:0],
    input  wire [NUM_CHANNELS-1:0] mem_read_ready,
    input  wire [DATA_BITS-1:0] mem_read_data [NUM_CHANNELS-1:0],
    output reg  [NUM_CHANNELS-1:0] mem_write_valid,
    output reg  [ADDR_BITS-1:0] mem_write_address [NUM_CHANNELS-1:0],
    output reg  [DATA_BITS-1:0] mem_write_data [NUM_CHANNELS-1:0],
    input  wire [NUM_CHANNELS-1:0] mem_write_ready,

    // Aggregated effectiveness counters (upstream reads only - every write
    // goes external by construction). External read beats on the pins equal
    // l2_miss_count * WORDS_PER_LINE (each miss is one full-line burst).
    output reg [31:0] l2_hit_count,
    output reg [31:0] l2_miss_count
);
    localparam OFF_BITS  = $clog2(WORDS_PER_LINE);   // word-in-line
    localparam BANK_BITS = $clog2(NUM_CHANNELS);     // home bank
    localparam SET_BITS  = $clog2(LINES_PER_BANK);   // set within bank
    localparam TAG_BITS  = ADDR_BITS - OFF_BITS - BANK_BITS - SET_BITS;

    // Per-bank FSM. Ready pulses last one cycle; DRAIN waits for the owning
    // channel's (registered) valid to drop so a stale ready can never be
    // mistaken for the ack of a new request.
    localparam IDLE    = 3'b000,
        FILL    = 3'b001,  // burst beat request in flight
        FILL_GAP = 3'b010, // 1-cycle gap: issue the next beat's address
        WEXT    = 3'b011,  // external write-through in flight
        DRAIN_R = 3'b101,  // read served; wait for owner's valid to drop
        DRAIN_W = 3'b110;  // write served; wait for owner's valid to drop

    reg [2:0] bank_state [NUM_CHANNELS-1:0];
    // Which upstream channel this bank is currently serving.
    reg [BANK_BITS:0] bank_owner [NUM_CHANNELS-1:0];
    // Latched request (address/data) and burst progress.
    reg [ADDR_BITS-1:0] pending_addr [NUM_CHANNELS-1:0];
    reg [DATA_BITS-1:0] pending_data [NUM_CHANNELS-1:0];
    reg [OFF_BITS:0]    fill_cnt     [NUM_CHANNELS-1:0];

    // Bank storage, flattened (sv2v/iverilog-safe):
    //   word slot  = ((b*LINES_PER_BANK) + set) * WORDS_PER_LINE + word
    //   tag slot   =  (b*LINES_PER_BANK) + set
    reg [DATA_BITS-1:0] line_data  [NUM_CHANNELS*LINES_PER_BANK*WORDS_PER_LINE-1:0];
    reg [TAG_BITS-1:0]  line_tag   [NUM_CHANNELS*LINES_PER_BANK-1:0];
    reg                 line_valid [NUM_CHANNELS*LINES_PER_BANK-1:0];

    integer b, c, k;

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
                bank_owner[k] <= '0;
                up_read_data[k] <= {DATA_BITS{1'b0}};
                mem_read_address[k] <= {ADDR_BITS{1'b0}};
                mem_write_address[k] <= {ADDR_BITS{1'b0}};
                mem_write_data[k] <= {DATA_BITS{1'b0}};
                pending_addr[k] <= {ADDR_BITS{1'b0}};
                pending_data[k] <= {DATA_BITS{1'b0}};
                fill_cnt[k] <= '0;
            end
            for (k = 0; k < NUM_CHANNELS*LINES_PER_BANK; k = k + 1) begin
                line_valid[k] <= 1'b0;
                line_tag[k] <= {TAG_BITS{1'b0}};
            end
            for (k = 0; k < NUM_CHANNELS*LINES_PER_BANK*WORDS_PER_LINE; k = k + 1) begin
                line_data[k] <= {DATA_BITS{1'b0}};
            end
        end else begin
            // Same-cycle counter increments from several banks accumulate in
            // blocking locals (per-bank NBA increments would collapse to +1).
            reg [31:0] hits_now;
            reg [31:0] misses_now;
            hits_now = 32'b0;
            misses_now = 32'b0;

            for (b = 0; b < NUM_CHANNELS; b = b + 1) begin
                // ---- Arbitration: pick an upstream request homed here ----
                logic        pick_valid;
                logic        pick_is_read;
                logic [BANK_BITS:0] pick_ch;
                logic [ADDR_BITS-1:0] pick_addr;
                // Decoded fields of the picked / pending address.
                logic [SET_BITS-1:0] a_set;
                logic [TAG_BITS-1:0] a_tag;
                logic [31:0] tag_slot;
                logic [31:0] word_slot;

                pick_valid = 1'b0;
                pick_is_read = 1'b0;
                pick_ch = '0;
                pick_addr = '0;
                // Reads first (they block a warp), then writes; lowest
                // channel index wins. Banks are independent, so distinct
                // lines proceed in parallel across banks.
                for (c = NUM_CHANNELS - 1; c >= 0; c = c - 1) begin
                    if (up_write_valid[c] && !up_write_ready[c]
                        && up_write_address[c][OFF_BITS+BANK_BITS-1:OFF_BITS] == b[BANK_BITS-1:0]) begin
                        pick_valid = 1'b1;
                        pick_is_read = 1'b0;
                        pick_ch = c[BANK_BITS:0];
                        pick_addr = up_write_address[c];
                    end
                end
                for (c = NUM_CHANNELS - 1; c >= 0; c = c - 1) begin
                    if (up_read_valid[c] && !up_read_ready[c]
                        && up_read_address[c][OFF_BITS+BANK_BITS-1:OFF_BITS] == b[BANK_BITS-1:0]) begin
                        pick_valid = 1'b1;
                        pick_is_read = 1'b1;
                        pick_ch = c[BANK_BITS:0];
                        pick_addr = up_read_address[c];
                    end
                end

                unique case (bank_state[b])
                    IDLE: begin
                        if (pick_valid) begin
                            a_set = pick_addr[OFF_BITS+BANK_BITS+SET_BITS-1:OFF_BITS+BANK_BITS];
                            a_tag = pick_addr[ADDR_BITS-1:OFF_BITS+BANK_BITS+SET_BITS];
                            tag_slot = b * LINES_PER_BANK + {{(32-SET_BITS){1'b0}}, a_set};
                            word_slot = tag_slot * WORDS_PER_LINE
                                + {{(32-OFF_BITS){1'b0}}, pick_addr[OFF_BITS-1:0]};
                            bank_owner[b] <= pick_ch;
                            pending_addr[b] <= pick_addr;

                            if (pick_is_read) begin
                                if (line_valid[tag_slot] && line_tag[tag_slot] == a_tag) begin
                                    // Read hit: serve the word in one pulse.
                                    up_read_data[pick_ch] <= line_data[word_slot];
                                    up_read_ready[pick_ch] <= 1'b1;
                                    hits_now = hits_now + 1;
                                    bank_state[b] <= DRAIN_R;
                                end else begin
                                    // Read miss: burst-fill the whole line,
                                    // starting at its base address.
                                    mem_read_valid[b] <= 1'b1;
                                    mem_read_address[b] <=
                                        {pick_addr[ADDR_BITS-1:OFF_BITS], {OFF_BITS{1'b0}}};
                                    fill_cnt[b] <= '0;
                                    misses_now = misses_now + 1;
                                    bank_state[b] <= FILL;
                                end
                            end else begin
                                // Write-through to external memory.
                                pending_data[b] <= up_write_data[pick_ch[BANK_BITS-1:0]];
                                mem_write_valid[b] <= 1'b1;
                                mem_write_address[b] <= pick_addr;
                                mem_write_data[b] <= up_write_data[pick_ch[BANK_BITS-1:0]];
                                bank_state[b] <= WEXT;
                            end
                        end
                    end
                    FILL: begin
                        if (mem_read_ready[b]) begin
                            // One burst beat accepted: store the word. The
                            // request is withdrawn for one cycle (FILL_GAP)
                            // so the memory's ready/data can never be paired
                            // with the *next* beat's address by mistake -
                            // each beat is a clean valid/ready transaction.
                            a_set = pending_addr[b][OFF_BITS+BANK_BITS+SET_BITS-1:OFF_BITS+BANK_BITS];
                            tag_slot = b * LINES_PER_BANK + {{(32-SET_BITS){1'b0}}, a_set};
                            line_data[tag_slot * WORDS_PER_LINE
                                      + {{(32-OFF_BITS){1'b0}}, fill_cnt[b][OFF_BITS-1:0]}]
                                <= mem_read_data[b];
                            // Capture the originally requested word for the
                            // upstream reply as it streams past.
                            if (fill_cnt[b][OFF_BITS-1:0] == pending_addr[b][OFF_BITS-1:0]) begin
                                up_read_data[bank_owner[b]] <= mem_read_data[b];
                            end
                            mem_read_valid[b] <= 1'b0;

                            if (fill_cnt[b] == WORDS_PER_LINE - 1) begin
                                // Line complete: validate and serve upstream.
                                line_tag[tag_slot] <=
                                    pending_addr[b][ADDR_BITS-1:OFF_BITS+BANK_BITS+SET_BITS];
                                line_valid[tag_slot] <= 1'b1;
                                up_read_ready[bank_owner[b]] <= 1'b1;
                                bank_state[b] <= DRAIN_R;
                            end else begin
                                fill_cnt[b] <= fill_cnt[b] + 1'b1;
                                bank_state[b] <= FILL_GAP;
                            end
                        end
                    end
                    FILL_GAP: begin
                        // Issue the next sequential beat of the burst.
                        mem_read_valid[b] <= 1'b1;
                        mem_read_address[b] <=
                            {pending_addr[b][ADDR_BITS-1:OFF_BITS], {OFF_BITS{1'b0}}}
                            + {{(ADDR_BITS-OFF_BITS-1){1'b0}}, fill_cnt[b]};
                        bank_state[b] <= FILL;
                    end
                    DRAIN_R: begin
                        up_read_ready[bank_owner[b]] <= 1'b0;
                        if (!up_read_valid[bank_owner[b]]) begin
                            bank_state[b] <= IDLE;
                        end
                    end
                    WEXT: begin
                        if (mem_write_ready[b]) begin
                            mem_write_valid[b] <= 1'b0;
                            // Update-if-resident (no-allocate on miss). This
                            // bank is the address's only possible home, so
                            // no other copy can exist anywhere.
                            a_set = pending_addr[b][OFF_BITS+BANK_BITS+SET_BITS-1:OFF_BITS+BANK_BITS];
                            a_tag = pending_addr[b][ADDR_BITS-1:OFF_BITS+BANK_BITS+SET_BITS];
                            tag_slot = b * LINES_PER_BANK + {{(32-SET_BITS){1'b0}}, a_set};
                            if (line_valid[tag_slot] && line_tag[tag_slot] == a_tag) begin
                                line_data[tag_slot * WORDS_PER_LINE
                                          + {{(32-OFF_BITS){1'b0}}, pending_addr[b][OFF_BITS-1:0]}]
                                    <= pending_data[b];
                            end
                            up_write_ready[bank_owner[b]] <= 1'b1;
                            bank_state[b] <= DRAIN_W;
                        end
                    end
                    DRAIN_W: begin
                        up_write_ready[bank_owner[b]] <= 1'b0;
                        if (!up_write_valid[bank_owner[b]]) begin
                            bank_state[b] <= IDLE;
                        end
                    end
                    default: bank_state[b] <= IDLE;
                endcase
            end

            l2_hit_count <= l2_hit_count + hits_now;
            l2_miss_count <= l2_miss_count + misses_now;
        end
    end
endmodule
