// Formal properties for the INSTRUCTION FETCHER handshake.
//
// Wired in via formal/fetcher/fetcher_formal_top.sv; never perturbs the
// synthesizable RTL. Verified with yosys + yices2 (SymbiYosys, k-induction).
//
// Style mirrors dcr_props.sv / scheduler_props.sv: immediate `assert` inside a
// clocked block with manual one-cycle history shadows (`past_*`).
//
// The fetcher drives a classic valid/ready read handshake to program memory
// and additionally performs speculative next-line prefetch (static BTFN
// prediction) once the core enters DECODE. These are the standard handshake
// safety invariants, extended over the 5-state FSM:
//
//   reset_state        : after reset, IDLE with the read request deasserted.
//   valid_iff_fetching : mem_read_valid is high exactly while a request is in
//                        flight (demand FETCHING or speculative SPEC_FETCHING).
//   legal_transition   : the 5-state FSM only advances along legal edges.
//   addr_stable        : while a request is outstanding (valid & !ready) the
//                        address payload and valid are held stable (AXI-style
//                        "no change while waiting for ack").
//   ack_clears_valid   : once the read is acked, valid drops -- no double-issue
//                        of the same request.

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

    localparam [2:0] IDLE          = 3'b000,
                     FETCHING      = 3'b001,
                     FETCHED       = 3'b010,
                     SPEC_FETCHING = 3'b011,
                     SPEC_READY    = 3'b100;

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

            // legal_transition: the 5-state FSM only advances along legal edges.
            if (!past_reset) begin
                case (past_fetcher_state)
                    IDLE:     assert (fetcher_state == IDLE || fetcher_state == FETCHING);
                    FETCHING: assert (fetcher_state == FETCHING || fetcher_state == FETCHED);
                    // FETCHED holds until DECODE, then either idles (RET) or
                    // launches the speculative prefetch.
                    FETCHED:  assert (fetcher_state == FETCHED || fetcher_state == IDLE
                                      || fetcher_state == SPEC_FETCHING);
                    // A landing speculative fetch is consumed (FETCHED),
                    // buffered (SPEC_READY), or discarded on mispredict (IDLE).
                    SPEC_FETCHING: assert (fetcher_state == SPEC_FETCHING
                                           || fetcher_state == FETCHED
                                           || fetcher_state == SPEC_READY
                                           || fetcher_state == IDLE);
                    // A buffered prediction is consumed (FETCHED) or replaced
                    // by a demand fetch on mispredict (FETCHING).
                    SPEC_READY: assert (fetcher_state == SPEC_READY
                                        || fetcher_state == FETCHED
                                        || fetcher_state == FETCHING);
                    default:  assert (1'b0); // FSM never reaches an illegal encoding
                endcase
            end

            // addr_stable: an outstanding request (demand or speculative, not
            // yet acked) holds its address payload and keeps valid asserted.
            if (!past_reset
                && (past_fetcher_state == FETCHING || past_fetcher_state == SPEC_FETCHING)
                && !past_mem_read_ready) begin
                assert (fetcher_state == past_fetcher_state);
                assert (mem_read_valid == 1'b1);
                assert (mem_read_address == past_mem_read_address);
            end

            // ack_clears_valid: once the read is acked, valid drops -- the
            // request is never re-issued.
            if (!past_reset && past_fetcher_state == FETCHING && past_mem_read_ready) begin
                assert (fetcher_state == FETCHED);
                assert (mem_read_valid == 1'b0);
            end
            if (!past_reset && past_fetcher_state == SPEC_FETCHING && past_mem_read_ready) begin
                assert (fetcher_state == FETCHED || fetcher_state == SPEC_READY
                        || fetcher_state == IDLE);
                assert (mem_read_valid == 1'b0);
            end

            // valid_iff_fetching: the read request is asserted exactly while a
            // demand or speculative fetch is in flight.
            assert (mem_read_valid == (fetcher_state == FETCHING
                                       || fetcher_state == SPEC_FETCHING));
        end
    end

endmodule
