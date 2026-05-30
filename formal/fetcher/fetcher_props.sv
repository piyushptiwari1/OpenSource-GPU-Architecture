// Formal properties for the INSTRUCTION FETCHER handshake.
//
// Wired in via formal/fetcher/fetcher_formal_top.sv; never perturbs the
// synthesizable RTL. Verified with yosys + yices2 (SymbiYosys, k-induction).
//
// Style mirrors dcr_props.sv / scheduler_props.sv: immediate `assert` inside a
// clocked block with manual one-cycle history shadows (`past_*`).
//
// The fetcher drives a classic valid/ready read handshake to program memory.
// These are the standard handshake safety invariants:
//
//   reset_state        : after reset, IDLE with the read request deasserted.
//   valid_iff_fetching : mem_read_valid is high exactly in the FETCHING state.
//   legal_transition   : the 3-state FSM only advances along legal edges.
//   addr_stable        : while a request is outstanding (valid & !ready) the
//                        address payload and valid are held stable (AXI-style
//                        "no change while waiting for ack").
//   ack_clears_valid   : once the read is acked (ready in FETCHING) valid drops
//                        and the FSM advances -- no double-issue of the request.

`default_nettype none
`timescale 1ns/1ns

module fetcher_props #(
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16
) (
    input wire                              clk,
    input wire                              reset,
    input wire [2:0]                        core_state,
    input wire [2:0]                        fetcher_state,
    input wire                              mem_read_valid,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0]  mem_read_address,
    input wire                              mem_read_ready
);

    localparam [2:0] IDLE     = 3'b000,
                     FETCHING = 3'b001,
                     FETCHED  = 3'b010;

    // One-cycle history shadows.
    reg                              past_valid;
    reg                              past_reset;
    reg [2:0]                        past_fetcher_state;
    reg                              past_mem_read_ready;
    reg [PROGRAM_MEM_ADDR_BITS-1:0]  past_mem_read_address;

    initial begin
        past_valid            = 1'b0;
        past_reset            = 1'b1;
        past_fetcher_state    = IDLE;
        past_mem_read_ready   = 1'b0;
        past_mem_read_address = '0;
    end

    always @(posedge clk) begin
        past_valid            <= 1'b1;
        past_reset            <= reset;
        past_fetcher_state    <= fetcher_state;
        past_mem_read_ready   <= mem_read_ready;
        past_mem_read_address <= mem_read_address;
    end

    // The fetcher flops have no initial value, so constrain the harness to begin
    // in reset (mirrors the per-block reset the core always pulses first).
    always @(*) begin
        if (!past_valid) begin
            assume (reset);
        end
    end

    always @(posedge clk) begin
        if (past_valid) begin
            // reset_state: a reset cycle drives IDLE with no outstanding request.
            if (past_reset) begin
                assert (fetcher_state == IDLE);
                assert (mem_read_valid == 1'b0);
            end

            // legal_transition: the 3-state FSM only advances along legal edges.
            if (!past_reset) begin
                case (past_fetcher_state)
                    IDLE:     assert (fetcher_state == IDLE || fetcher_state == FETCHING);
                    FETCHING: assert (fetcher_state == FETCHING || fetcher_state == FETCHED);
                    FETCHED:  assert (fetcher_state == FETCHED || fetcher_state == IDLE);
                    default:  assert (1'b0); // FSM never reaches an illegal encoding
                endcase
            end

            // addr_stable: an outstanding request (was FETCHING, not yet acked)
            // holds its address payload and keeps valid asserted.
            if (!past_reset && past_fetcher_state == FETCHING && !past_mem_read_ready) begin
                assert (fetcher_state == FETCHING);
                assert (mem_read_valid == 1'b1);
                assert (mem_read_address == past_mem_read_address);
            end

            // ack_clears_valid: once the read is acked, valid drops and the FSM
            // advances to FETCHED -- the request is never re-issued.
            if (!past_reset && past_fetcher_state == FETCHING && past_mem_read_ready) begin
                assert (fetcher_state == FETCHED);
                assert (mem_read_valid == 1'b0);
            end

            // valid_iff_fetching: the read request is asserted exactly while the
            // FSM is in FETCHING.
            assert (mem_read_valid == (fetcher_state == FETCHING));
        end
    end

endmodule
