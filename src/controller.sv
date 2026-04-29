`default_nettype none
`timescale 1ns/1ns

// MEMORY CONTROLLER
// > Receives memory requests from all cores
// > Throttles requests based on limited external memory bandwidth
// > Waits for responses from external memory and distributes them back to cores
module controller #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter NUM_CONSUMERS = 4, // The number of consumers accessing memory through this controller
    parameter NUM_CHANNELS = 1,  // The number of concurrent channels available to send requests to global memory
    parameter WRITE_ENABLE = 1   // Whether this memory controller can write to memory (program memory is read-only)
) (
    input wire clk,
    input wire reset,

    // Consumer Interface (Fetchers / LSUs)
    input [NUM_CONSUMERS-1:0] consumer_read_valid,
    input [ADDR_BITS-1:0] consumer_read_address [NUM_CONSUMERS-1:0],
    output reg [NUM_CONSUMERS-1:0] consumer_read_ready,
    output reg [DATA_BITS-1:0] consumer_read_data [NUM_CONSUMERS-1:0],
    input [NUM_CONSUMERS-1:0] consumer_write_valid,
    input [ADDR_BITS-1:0] consumer_write_address [NUM_CONSUMERS-1:0],
    input [DATA_BITS-1:0] consumer_write_data [NUM_CONSUMERS-1:0],
    output reg [NUM_CONSUMERS-1:0] consumer_write_ready,

    // Atomicity: each consumer asserts consumer_atomic for the entire
    // duration of an atomic read-modify-write. The controller locks the
    // target address against other consumers from the moment it accepts
    // the read until it completes the matching write.
    input [NUM_CONSUMERS-1:0] consumer_atomic,

    // Memory Interface (Data / Program)
    output reg [NUM_CHANNELS-1:0] mem_read_valid,
    output reg [ADDR_BITS-1:0] mem_read_address [NUM_CHANNELS-1:0],
    input [NUM_CHANNELS-1:0] mem_read_ready,
    input [DATA_BITS-1:0] mem_read_data [NUM_CHANNELS-1:0],
    output reg [NUM_CHANNELS-1:0] mem_write_valid,
    output reg [ADDR_BITS-1:0] mem_write_address [NUM_CHANNELS-1:0],
    output reg [DATA_BITS-1:0] mem_write_data [NUM_CHANNELS-1:0],
    input [NUM_CHANNELS-1:0] mem_write_ready
);
    localparam IDLE = 3'b000, 
        READ_WAITING = 3'b010, 
        WRITE_WAITING = 3'b011,
        READ_RELAYING = 3'b100,
        WRITE_RELAYING = 3'b101,
        ATOMIC_HOLD    = 3'b110; // After atomic read-relay, waits for owner's write

    // Keep track of state for each channel and which jobs each channel is handling
    reg [2:0] controller_state [NUM_CHANNELS-1:0];
    reg [$clog2(NUM_CONSUMERS)-1:0] current_consumer [NUM_CHANNELS-1:0]; // Which consumer is each channel currently serving
    reg [NUM_CONSUMERS-1:0] channel_serving_consumer; // Which channels are being served? Prevents many workers from picking up the same request.

    // Per-channel atomic address lock. While `atomic_lock_valid[c]` is set,
    // no other channel may issue a read or write to `atomic_lock_addr[c]`.
    reg [NUM_CHANNELS-1:0]   atomic_lock_valid;
    reg [ADDR_BITS-1:0]      atomic_lock_addr [NUM_CHANNELS-1:0];

    always @(posedge clk) begin
        if (reset) begin 
            // Packed vector resets (driven as a single bit-vector)
            mem_read_valid <= {NUM_CHANNELS{1'b0}};
            mem_write_valid <= {NUM_CHANNELS{1'b0}};
            consumer_read_ready <= {NUM_CONSUMERS{1'b0}};
            consumer_write_ready <= {NUM_CONSUMERS{1'b0}};

            // Unpacked-array resets (Quartus Prime 18.1 rejects scalar-to-array
            // shorthand, so we initialize each element explicitly).
            // Fixes upstream issue #25.
            for (int k = 0; k < NUM_CHANNELS; k = k + 1) begin
                mem_read_address[k] <= {ADDR_BITS{1'b0}};
                mem_write_address[k] <= {ADDR_BITS{1'b0}};
                mem_write_data[k] <= {DATA_BITS{1'b0}};
                current_consumer[k] <= 0;
                controller_state[k] <= IDLE;
                atomic_lock_addr[k] <= {ADDR_BITS{1'b0}};
            end
            atomic_lock_valid <= {NUM_CHANNELS{1'b0}};
            for (int k = 0; k < NUM_CONSUMERS; k = k + 1) begin
                consumer_read_data[k] <= {DATA_BITS{1'b0}};
            end

            channel_serving_consumer = {NUM_CONSUMERS{1'b0}};
        end else begin 
            // Local variable to handle arbitration updates within the same cycle
            reg [NUM_CONSUMERS-1:0] next_channel_serving_consumer;
            // Tentative atomic locks acquired this cycle so multiple channels
            // arbitrating concurrently observe each other's pending locks.
            reg [NUM_CHANNELS-1:0]  next_atomic_lock_valid;
            reg [ADDR_BITS-1:0]     next_atomic_lock_addr [NUM_CHANNELS-1:0];
            next_channel_serving_consumer = channel_serving_consumer;
            next_atomic_lock_valid = atomic_lock_valid;
            for (int k = 0; k < NUM_CHANNELS; k = k + 1) begin
                next_atomic_lock_addr[k] = atomic_lock_addr[k];
            end

            // For each channel, we handle processing concurrently
            for (int i = 0; i < NUM_CHANNELS; i = i + 1) begin 
                // FSM states are mutually exclusive; unique case helps the
                // synthesizer infer a true mux and emit a warning if multiple
                // states match (issue #20).
                unique case (controller_state[i])
                    IDLE: begin
                        // While this channel is idle, cycle through consumers looking for one with a pending request
                        for (int j = 0; j < NUM_CONSUMERS; j = j + 1) begin 
                            if (consumer_read_valid[j] && !next_channel_serving_consumer[j]) begin
                                // Honor active atomic locks on this address held by other channels.
                                logic addr_locked_r;
                                addr_locked_r = 1'b0;
                                for (int c = 0; c < NUM_CHANNELS; c = c + 1) begin
                                    if (c != i && next_atomic_lock_valid[c]
                                        && next_atomic_lock_addr[c] == consumer_read_address[j]) begin
                                        addr_locked_r = 1'b1;
                                    end
                                end
                                if (addr_locked_r) continue;

                                next_channel_serving_consumer[j] = 1;
                                current_consumer[i] <= j;

                                mem_read_valid[i] <= 1;
                                mem_read_address[i] <= consumer_read_address[j];
                                controller_state[i] <= READ_WAITING;

                                // Acquire atomic lock for the entire RMW window (visible same-cycle).
                                if (consumer_atomic[j]) begin
                                    next_atomic_lock_valid[i] = 1'b1;
                                    next_atomic_lock_addr[i]  = consumer_read_address[j];
                                end

                                // Once we find a pending request, pick it up with this channel and stop looking for requests
                                break;
                            end else if (consumer_write_valid[j] && !next_channel_serving_consumer[j]) begin
                                // Plain (non-atomic) writes also respect existing atomic locks.
                                logic addr_locked_w;
                                addr_locked_w = 1'b0;
                                for (int c = 0; c < NUM_CHANNELS; c = c + 1) begin
                                    if (c != i && next_atomic_lock_valid[c]
                                        && next_atomic_lock_addr[c] == consumer_write_address[j]) begin
                                        addr_locked_w = 1'b1;
                                    end
                                end
                                if (addr_locked_w) continue;

                                next_channel_serving_consumer[j] = 1;
                                current_consumer[i] <= j;

                                mem_write_valid[i] <= 1;
                                mem_write_address[i] <= consumer_write_address[j];
                                mem_write_data[i] <= consumer_write_data[j];
                                controller_state[i] <= WRITE_WAITING;

                                // Once we find a pending request, pick it up with this channel and stop looking for requests
                                break;
                            end
                        end
                    end
                    READ_WAITING: begin
                        // Wait for response from memory for pending read request
                        if (mem_read_ready[i]) begin 
                            mem_read_valid[i] <= 0;
                            consumer_read_ready[current_consumer[i]] <= 1;
                            consumer_read_data[current_consumer[i]] <= mem_read_data[i];
                            controller_state[i] <= READ_RELAYING;
                        end
                    end
                    WRITE_WAITING: begin 
                        // Wait for response from memory for pending write request
                        if (mem_write_ready[i]) begin 
                            mem_write_valid[i] <= 0;
                            consumer_write_ready[current_consumer[i]] <= 1;
                            controller_state[i] <= WRITE_RELAYING;
                        end
                    end
                    // Wait until consumer acknowledges it received response, then reset
                    READ_RELAYING: begin
                        if (!consumer_read_valid[current_consumer[i]]) begin 
                            consumer_read_ready[current_consumer[i]] <= 0;
                            // For atomic consumers, keep the channel-consumer
                            // binding (and the address lock) and wait for the
                            // owner's matching write to come in.
                            if (consumer_atomic[current_consumer[i]]) begin
                                controller_state[i] <= ATOMIC_HOLD;
                            end else begin
                                next_channel_serving_consumer[current_consumer[i]] = 0;
                                controller_state[i] <= IDLE;
                            end
                        end
                    end
                    ATOMIC_HOLD: begin
                        // Same channel waits for the owning consumer to issue
                        // its write (the W half of the RMW). The address lock
                        // remains in effect throughout.
                        if (consumer_write_valid[current_consumer[i]]) begin
                            mem_write_valid[i] <= 1;
                            mem_write_address[i] <= consumer_write_address[current_consumer[i]];
                            mem_write_data[i] <= consumer_write_data[current_consumer[i]];
                            controller_state[i] <= WRITE_WAITING;
                        end
                    end
                    WRITE_RELAYING: begin 
                        if (!consumer_write_valid[current_consumer[i]]) begin 
                            next_channel_serving_consumer[current_consumer[i]] = 0;
                            consumer_write_ready[current_consumer[i]] <= 0;
                            // Release atomic lock if this channel was holding one.
                            if (next_atomic_lock_valid[i]) begin
                                next_atomic_lock_valid[i] = 1'b0;
                            end
                            controller_state[i] <= IDLE;
                        end
                    end
                    default: ; // Unused encodings: hold state.
                endcase
            end
            
            // Update the state register
            channel_serving_consumer <= next_channel_serving_consumer;
            atomic_lock_valid <= next_atomic_lock_valid;
            for (int k = 0; k < NUM_CHANNELS; k = k + 1) begin
                atomic_lock_addr[k] <= next_atomic_lock_addr[k];
            end
        end
    end
endmodule
