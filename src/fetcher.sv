`default_nettype none
`timescale 1ns/1ns

// INSTRUCTION FETCHER (pipelined front-end)
// > Retrieves the instruction at the current PC from program memory
// > Each core has it's own fetcher
//
// Speculative next-line prefetch
// ------------------------------
// The original fetcher sat idle from DECODE through UPDATE while the rest of
// the core executed - then the next FETCH paid the full memory round-trip
// again. This version overlaps that round-trip with execution:
//
//   * As soon as the core moves into DECODE, the fetcher speculatively begins
//     fetching the *predicted* next instruction (static BTFN prediction:
//     BRnzp with a backward target is predicted taken, everything else is
//     predicted to fall through to PC+1).
//   * When the core re-enters FETCH, a correct prediction is served in a
//     single cycle from the speculation buffer (or as soon as the in-flight
//     request lands). A misprediction is discarded and refetched - always
//     correct, sometimes slower.
//   * After a RET the fetcher does not speculate (the warp is about to retire
//     lanes or finish the block, so a prefetch would mostly fetch garbage).
//
// Speculation is safe because program-memory reads are side-effect free, and
// the speculative request is downstream of the per-core icache, so a correct
// prediction usually costs no external bandwidth at all.
module fetcher #(
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16
) (
    input wire clk,
    input wire reset,
    
    // Execution State
    input [2:0] core_state,
    input [7:0] current_pc,

    // Program Memory
    output reg mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] mem_read_address,
    input mem_read_ready,
    input [PROGRAM_MEM_DATA_BITS-1:0] mem_read_data,

    // Fetcher Output
    output reg [2:0] fetcher_state,
    output reg [PROGRAM_MEM_DATA_BITS-1:0] instruction
);
    localparam IDLE = 3'b000, 
        FETCHING = 3'b001, 
        FETCHED = 3'b010,
        SPEC_FETCHING = 3'b011,  // Speculative prefetch request in flight
        SPEC_READY = 3'b100;     // Speculative instruction buffered, waiting for next FETCH

    // Opcodes the predictor cares about.
    localparam OPCODE_BRNZP = 4'b0001,
        OPCODE_RET = 4'b1111;

    // PC of the instruction currently held in `instruction`.
    reg [PROGRAM_MEM_ADDR_BITS-1:0] fetched_pc;
    // Predicted PC being (or already) speculatively fetched.
    reg [PROGRAM_MEM_ADDR_BITS-1:0] spec_pc;
    // Buffered speculative instruction (valid in SPEC_READY).
    reg [PROGRAM_MEM_DATA_BITS-1:0] spec_instruction;

    // Static BTFN (backward-taken / forward-not-taken) prediction, computed
    // from the *fetched* instruction:
    //   BRnzp with target <= this instruction's PC -> loop edge, predict taken
    //   anything else                              -> predict fall-through
    wire is_branch = (instruction[15:12] == OPCODE_BRNZP);
    wire is_ret = (instruction[15:12] == OPCODE_RET);
    wire [PROGRAM_MEM_ADDR_BITS-1:0] branch_target = instruction[7:0];
    wire [PROGRAM_MEM_ADDR_BITS-1:0] predicted_pc =
        (is_branch && (branch_target <= fetched_pc)) ? branch_target
                                                     : fetched_pc + 1;

    always @(posedge clk) begin
        if (reset) begin
            fetcher_state <= IDLE;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            instruction <= {PROGRAM_MEM_DATA_BITS{1'b0}};
            fetched_pc <= 0;
            spec_pc <= 0;
            spec_instruction <= {PROGRAM_MEM_DATA_BITS{1'b0}};
        end else begin
            case (fetcher_state)
                IDLE: begin
                    // Start fetching when core_state = FETCH
                    if (core_state == 3'b001) begin
                        fetcher_state <= FETCHING;
                        mem_read_valid <= 1;
                        mem_read_address <= current_pc;
                        fetched_pc <= current_pc;
                    end
                end
                FETCHING: begin
                    // Wait for response from program memory
                    if (mem_read_ready) begin
                        fetcher_state <= FETCHED;
                        instruction <= mem_read_data; // Store the instruction when received
                        mem_read_valid <= 0;
                    end
                end
                FETCHED: begin
                    // The core has the instruction; once it starts DECODE the
                    // fetch port is free, so begin the speculative prefetch of
                    // the predicted next instruction (except after RET).
                    if (core_state == 3'b010) begin
                        if (is_ret) begin
                            fetcher_state <= IDLE;
                        end else begin
                            fetcher_state <= SPEC_FETCHING;
                            mem_read_valid <= 1;
                            mem_read_address <= predicted_pc;
                            spec_pc <= predicted_pc;
                        end
                    end
                end
                SPEC_FETCHING: begin
                    // Speculative request in flight while the core executes.
                    // The request payload is held stable until acknowledged
                    // (same handshake contract as a demand fetch).
                    if (mem_read_ready) begin
                        mem_read_valid <= 0;
                        if (core_state == 3'b001 && current_pc == spec_pc) begin
                            // The core is already waiting on this address:
                            // deliver it directly as a completed demand fetch.
                            instruction <= mem_read_data;
                            fetched_pc <= spec_pc;
                            fetcher_state <= FETCHED;
                        end else if (core_state == 3'b001) begin
                            // The core wants a different address (mispredict):
                            // drop the speculative data and restart cleanly.
                            fetcher_state <= IDLE;
                        end else begin
                            // Core still executing: buffer the result.
                            spec_instruction <= mem_read_data;
                            fetcher_state <= SPEC_READY;
                        end
                    end
                end
                SPEC_READY: begin
                    // Buffered prediction; resolve it when the core fetches.
                    if (core_state == 3'b001) begin
                        if (current_pc == spec_pc) begin
                            // Prediction correct: single-cycle fetch.
                            instruction <= spec_instruction;
                            fetched_pc <= spec_pc;
                            fetcher_state <= FETCHED;
                        end else begin
                            // Mispredict: discard and issue the demand fetch.
                            fetcher_state <= FETCHING;
                            mem_read_valid <= 1;
                            mem_read_address <= current_pc;
                            fetched_pc <= current_pc;
                        end
                    end
                end
                default: begin
                    fetcher_state <= IDLE;
                end
            endcase
        end
    end
endmodule

