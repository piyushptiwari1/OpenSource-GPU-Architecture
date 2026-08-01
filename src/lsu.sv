`default_nettype none
`timescale 1ns/1ns

// LOAD-STORE UNIT
// > Handles asynchronous memory load and store operations and waits for response
// > Each thread in each core has it's own LSU
// > LDR, STR instructions are executed here
module lsu (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some LSUs will be inactive

    // State
    input [2:0] core_state,

    // Completion handshake: high releases a finished (DONE) operation back
    // to IDLE. For synchronous ops the core drives this during the owning
    // instruction's UPDATE stage (the original behaviour); for POSTED ops it
    // is driven by the scoreboard's completion ack, which may arrive many
    // instructions later.
    input op_release,

    // Memory Control Sgiansl
    input decoded_mem_read_enable,
    input decoded_mem_write_enable,
    // 0 = ATOMICADD (mem[Rs] <- old + Rt)
    // 1 = ATOMICCAS (if old == 0 then mem[Rs] <- Rt)
    input decoded_atomic_op,

    // Shared-memory address space selector (LDS/STS). When high, the request
    // is routed to the core-local banked shared memory via the shared_* port
    // set below instead of the global data-memory channel.
    input decoded_shared,

    // Registers
    input [7:0] rs,
    input [7:0] rt,

    // Data Memory
    output reg mem_read_valid,
    output reg [7:0] mem_read_address,
    input mem_read_ready,
    input [7:0] mem_read_data,
    output reg mem_write_valid,
    output reg [7:0] mem_write_address,
    output reg [7:0] mem_write_data,
    input mem_write_ready,

    // Per-block Shared Memory (banked, single-cycle island)
    output reg shared_read_valid,
    output reg [7:0] shared_read_address,
    input shared_read_ready,
    input [7:0] shared_read_data,
    output reg shared_write_valid,
    output reg [7:0] shared_write_address,
    output reg [7:0] shared_write_data,
    input shared_write_ready,

    // LSU Outputs
    output reg [1:0] lsu_state,
    output reg [7:0] lsu_out,

    // Atomic indication to memory controller (held high through RMW so that
    // the controller can lock the target address against other consumers).
    output wire consumer_atomic
);
    localparam IDLE = 2'b00, REQUESTING = 2'b01, WAITING = 2'b10, DONE = 2'b11;

    // ATOMICADD asserts both mem_read and mem_write. The atomic path
    // sequences read-then-write inside this single LSU using the same
    // 4-state FSM plus an internal phase flag (0 = read, 1 = write).
    // This gives lane-local atomicity (one warp lane cannot interleave
    // its own R and W); cross-warp atomicity additionally requires the
    // memory controller to serialise outstanding requests, which it
    // already does via mem_*_ready handshakes.
    wire is_atomic = decoded_mem_read_enable && decoded_mem_write_enable;
    reg  atomic_phase;  // 0 = read in flight, 1 = write in flight

    // Hold the atomic flag from the moment the LSU leaves IDLE until the
    // owning core completes the UPDATE phase (which transitions us back to
    // IDLE). This guarantees the controller's per-address lock spans the
    // full RMW window across all participating channels.
    assign consumer_atomic = is_atomic && (lsu_state != IDLE);

    always @(posedge clk) begin
        if (reset) begin
            lsu_state <= IDLE;
            lsu_out <= 0;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= 0;
            atomic_phase <= 0;
            shared_read_valid <= 0;
            shared_read_address <= 0;
            shared_write_valid <= 0;
            shared_write_address <= 0;
            shared_write_data <= 0;
        end else if (enable) begin
            // Shared-memory path (LDS/STS). Single-cycle banked island; reuses
            // the same 4-state handshake but on the shared_* port set. Shared
            // accesses are never atomic, so this branch is checked first.
            if (decoded_shared) begin
                if (decoded_mem_read_enable) begin
                    unique case (lsu_state)
                        IDLE: begin
                            if (core_state == 3'b011) begin
                                lsu_state <= REQUESTING;
                            end
                        end
                        REQUESTING: begin
                            shared_read_valid   <= 1;
                            shared_read_address <= rs;
                            lsu_state           <= WAITING;
                        end
                        WAITING: begin
                            if (shared_read_ready) begin
                                shared_read_valid <= 0;
                                lsu_out           <= shared_read_data;
                                lsu_state         <= DONE;
                            end
                        end
                        DONE: begin
                            if (op_release) begin
                                lsu_state <= IDLE;
                            end
                        end
                    endcase
                end else if (decoded_mem_write_enable) begin
                    unique case (lsu_state)
                        IDLE: begin
                            if (core_state == 3'b011) begin
                                lsu_state <= REQUESTING;
                            end
                        end
                        REQUESTING: begin
                            shared_write_valid   <= 1;
                            shared_write_address <= rs;
                            shared_write_data    <= rt;
                            lsu_state            <= WAITING;
                        end
                        WAITING: begin
                            if (shared_write_ready) begin
                                shared_write_valid <= 0;
                                lsu_state          <= DONE;
                            end
                        end
                        DONE: begin
                            if (op_release) begin
                                lsu_state <= IDLE;
                            end
                        end
                    endcase
                end
            end
            // Atomic read-modify-write path (ATOMICADD).
            else if (is_atomic) begin
                unique case (lsu_state)
                    IDLE: begin
                        if (core_state == 3'b011) begin
                            lsu_state    <= REQUESTING;
                            atomic_phase <= 0;
                        end
                    end
                    REQUESTING: begin
                        if (atomic_phase == 1'b0) begin
                            // Issue the read.
                            mem_read_valid   <= 1;
                            mem_read_address <= rs;
                        end else begin
                            // Issue the modified write.
                            // ATOMICADD: mem[Rs] <- old + Rt
                            // ATOMICCAS: if old == 0 then mem[Rs] <- Rt;
                            //            otherwise rewrite the old value
                            //            so the controller's lock-and-write
                            //            phase still completes cleanly.
                            mem_write_valid   <= 1;
                            mem_write_address <= rs;
                            if (decoded_atomic_op == 1'b0) begin
                                mem_write_data <= lsu_out + rt;
                            end else begin
                                mem_write_data <= (lsu_out == 8'b0) ? rt : lsu_out;
                            end
                        end
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (atomic_phase == 1'b0) begin
                            if (mem_read_ready) begin
                                mem_read_valid <= 0;
                                lsu_out        <= mem_read_data;  // Rd <- old
                                atomic_phase   <= 1;
                                lsu_state      <= REQUESTING;
                            end
                        end else begin
                            if (mem_write_ready) begin
                                mem_write_valid <= 0;
                                lsu_state       <= DONE;
                            end
                        end
                    end
                    DONE: begin
                        if (op_release) begin
                            lsu_state    <= IDLE;
                            atomic_phase <= 0;
                        end
                    end
                endcase
            end
            // Plain LDR.
            else if (decoded_mem_read_enable) begin
                // 4-state FSM, fully covered (issue #20).
                unique case (lsu_state)
                    IDLE: begin
                        // Only read when core_state = REQUEST
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        mem_read_valid <= 1;
                        mem_read_address <= rs;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (mem_read_ready == 1) begin
                            mem_read_valid <= 0;
                            lsu_out <= mem_read_data;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset when core_state = UPDATE
                        if (op_release) begin
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end

            // If memory write enable is triggered (STR instruction)
            else if (decoded_mem_write_enable) begin 
                // 4-state FSM, fully covered (issue #20).
                unique case (lsu_state)
                    IDLE: begin
                        // Only read when core_state = REQUEST
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        mem_write_valid <= 1;
                        mem_write_address <= rs;
                        mem_write_data <= rt;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (mem_write_ready) begin
                            mem_write_valid <= 0;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset when core_state = UPDATE
                        if (op_release) begin
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end
        end
    end
endmodule
