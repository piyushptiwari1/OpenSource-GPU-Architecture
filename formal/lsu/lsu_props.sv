// Formal properties for the LOAD-STORE UNIT handshake.
//
// Wired in via formal/lsu/lsu_formal_top.sv; never perturbs the synthesizable
// RTL. Verified with yosys + yices2 (SymbiYosys).
//
// Style mirrors fetcher_props.sv / scheduler_props.sv: immediate `assert`
// inside a clocked block with manual one-cycle history shadows (`past_*`).
//
// The LSU runs a 4-state handshake (IDLE -> REQUESTING -> WAITING -> DONE) that
// is shared across four request flavours: plain LDR / STR, an atomic
// read-modify-write (ATOMICADD/ATOMICCAS, which re-enters REQUESTING for the
// write half), and shared-memory LDS / STS on a parallel port set. Because the
// decoded-instruction selectors and `enable` are *free* inputs to the formal
// harness, we constrain them with the real core<->LSU contract:
//
//   ENV CONTRACT (assume): while a transaction is in flight (lsu_state != IDLE)
//   the upstream holds the decoded instruction (mem_read/mem_write/atomic_op/
//   shared) and `enable` stable. This mirrors the master-holds-request-stable
//   assumption used in every AXI/valid-ready formal proof; the core never
//   swaps the in-flight instruction out from under the LSU.
//
// Proven safety invariants (port-observable):
//
//   reset_state      : after reset, IDLE with every request line deasserted.
//   legal_transition : the 4-state FSM only advances along legal edges
//                      (incl. the atomic WAITING->REQUESTING write re-issue).
//   valid_mutex      : at most one of the four request-valid lines is asserted
//                      at a time (read/write and global/shared never overlap).
//   addr_stable      : an outstanding global read/write (valid & !ready) holds
//                      its address payload and keeps valid asserted.
//   ack_clears_valid : once a global read/write is acked in WAITING, the valid
//                      drops -- the request is never double-issued.
//
// Proof mode: BMC (bounded) from the reset state, depth 30, not k-induction.
// The LSU carries an unconstrained internal `atomic_phase` flag and registered
// request-valid lines whose values only make sense relative to the decoded
// instruction. Under k-induction the engine can pick an *unreachable* pre-state
// (e.g. atomic_phase=1 with mem_read_valid=1 while the decoded instruction is a
// plain write), so the handshake invariants are true on every reachable state
// but not 1-step inductive. Proving them by induction would need strengthening
// invariants over the internal atomic_phase/valid coupling (extra RTL coupling
// we deliberately avoid). BMC from reset -- depth 30 covers several full
// transactions including the atomic read-then-write re-issue -- gives the same
// bounded guarantee the dcr and dispatch proofs provide.

`default_nettype none
`timescale 1ns/1ns

module lsu_props (
    input wire       clk,
    input wire       reset,
    input wire       enable,
    input wire [2:0] core_state,
    input wire       decoded_mem_read_enable,
    input wire       decoded_mem_write_enable,
    input wire       decoded_atomic_op,
    input wire       decoded_shared,
    input wire [1:0] lsu_state,
    input wire       mem_read_valid,
    input wire [7:0] mem_read_address,
    input wire       mem_read_ready,
    input wire       mem_write_valid,
    input wire [7:0] mem_write_address,
    input wire [7:0] mem_write_data,
    input wire       mem_write_ready,
    input wire       shared_read_valid,
    input wire [7:0] shared_read_address,
    input wire       shared_read_ready,
    input wire       shared_write_valid,
    input wire [7:0] shared_write_address,
    input wire       shared_write_ready
);

    localparam [1:0] IDLE       = 2'b00,
                     REQUESTING = 2'b01,
                     WAITING    = 2'b10,
                     DONE       = 2'b11;

    // One-cycle history shadows.
    reg       past_valid;
    reg       past_reset;
    reg       past_enable;
    reg [1:0] past_lsu_state;
    reg       past_mem_read_valid;
    reg [7:0] past_mem_read_address;
    reg       past_mem_read_ready;
    reg       past_mem_write_valid;
    reg [7:0] past_mem_write_address;
    reg [7:0] past_mem_write_data;
    reg       past_mem_write_ready;
    reg       past_decoded_mem_read_enable;
    reg       past_decoded_mem_write_enable;
    reg       past_decoded_atomic_op;
    reg       past_decoded_shared;

    initial begin
        past_valid                    = 1'b0;
        past_reset                    = 1'b1;
        past_enable                   = 1'b0;
        past_lsu_state                = IDLE;
        past_mem_read_valid           = 1'b0;
        past_mem_read_address         = 8'b0;
        past_mem_read_ready           = 1'b0;
        past_mem_write_valid          = 1'b0;
        past_mem_write_address        = 8'b0;
        past_mem_write_data           = 8'b0;
        past_mem_write_ready          = 1'b0;
        past_decoded_mem_read_enable  = 1'b0;
        past_decoded_mem_write_enable = 1'b0;
        past_decoded_atomic_op        = 1'b0;
        past_decoded_shared           = 1'b0;
    end

    always @(posedge clk) begin
        past_valid                    <= 1'b1;
        past_reset                    <= reset;
        past_enable                   <= enable;
        past_lsu_state                <= lsu_state;
        past_mem_read_valid           <= mem_read_valid;
        past_mem_read_address         <= mem_read_address;
        past_mem_read_ready           <= mem_read_ready;
        past_mem_write_valid          <= mem_write_valid;
        past_mem_write_address        <= mem_write_address;
        past_mem_write_data           <= mem_write_data;
        past_mem_write_ready          <= mem_write_ready;
        past_decoded_mem_read_enable  <= decoded_mem_read_enable;
        past_decoded_mem_write_enable <= decoded_mem_write_enable;
        past_decoded_atomic_op        <= decoded_atomic_op;
        past_decoded_shared           <= decoded_shared;
    end

    // The LSU flops have no initial value, so constrain the harness to begin in
    // reset (mirrors the per-block reset the core always pulses first).
    always @(*) begin
        if (!past_valid) begin
            assume (reset);
        end
    end

    // ENV CONTRACT: the upstream holds the decoded instruction and `enable`
    // stable for the whole duration of a transaction (lsu_state != IDLE). The
    // core never changes the in-flight instruction mid-handshake.
    always @(posedge clk) begin
        if (past_valid && !past_reset && past_lsu_state != IDLE) begin
            assume (decoded_mem_read_enable  == past_decoded_mem_read_enable);
            assume (decoded_mem_write_enable == past_decoded_mem_write_enable);
            assume (decoded_atomic_op        == past_decoded_atomic_op);
            assume (decoded_shared           == past_decoded_shared);
            assume (enable                   == past_enable);
        end
    end

    always @(posedge clk) begin
        if (past_valid) begin
            // reset_state: a reset cycle drives IDLE with no outstanding request.
            if (past_reset) begin
                assert (lsu_state == IDLE);
                assert (mem_read_valid    == 1'b0);
                assert (mem_write_valid   == 1'b0);
                assert (shared_read_valid == 1'b0);
                assert (shared_write_valid == 1'b0);
            end

            // legal_transition: the 4-state FSM only advances along legal edges.
            // WAITING may return to REQUESTING for the atomic write re-issue.
            if (!past_reset) begin
                case (past_lsu_state)
                    IDLE:       assert (lsu_state == IDLE || lsu_state == REQUESTING);
                    REQUESTING: assert (lsu_state == REQUESTING || lsu_state == WAITING);
                    WAITING:    assert (lsu_state == WAITING || lsu_state == DONE
                                        || lsu_state == REQUESTING);
                    DONE:       assert (lsu_state == DONE || lsu_state == IDLE);
                    default:    assert (1'b0); // FSM never reaches an illegal encoding
                endcase
            end

            // valid_mutex: at most one request-valid line is high at a time.
            if (!past_reset) begin
                assert ($countones({mem_read_valid, mem_write_valid,
                                    shared_read_valid, shared_write_valid}) <= 1);
            end

            // addr_stable (global read): an outstanding read (valid & !ready)
            // holds its address payload and keeps valid asserted.
            if (!past_reset && past_mem_read_valid && !past_mem_read_ready) begin
                assert (mem_read_valid == 1'b1);
                assert (mem_read_address == past_mem_read_address);
            end

            // addr_stable (global write): an outstanding write holds address +
            // data payload and keeps valid asserted.
            if (!past_reset && past_mem_write_valid && !past_mem_write_ready) begin
                assert (mem_write_valid == 1'b1);
                assert (mem_write_address == past_mem_write_address);
                assert (mem_write_data == past_mem_write_data);
            end

            // ack_clears_valid (global read): once acked in WAITING, valid drops
            // -- the read is never double-issued.
            if (!past_reset && past_enable && past_lsu_state == WAITING
                && past_mem_read_valid && past_mem_read_ready) begin
                assert (mem_read_valid == 1'b0);
            end

            // ack_clears_valid (global write): once acked in WAITING, valid drops.
            if (!past_reset && past_enable && past_lsu_state == WAITING
                && past_mem_write_valid && past_mem_write_ready) begin
                assert (mem_write_valid == 1'b0);
            end
        end
    end

endmodule
