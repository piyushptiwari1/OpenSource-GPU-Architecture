// Formal properties for the PROGRAM COUNTER branch-decision logic.
//
// Wired in via formal/pc/pc_formal_top.sv; never perturbs the synthesizable
// RTL. Verified with yosys + yices2 (SymbiYosys, k-induction).
//
// Style mirrors fetcher_props.sv / scheduler_props.sv: immediate `assert`
// inside a clocked block with manual one-cycle history shadows (`past_*`).
//
// White-box: the internal NZP flag register is observed through a hierarchical
// reference in the formal top (`nzp`), so we can prove the actual branch target
// (not merely the port-observable "next_pc is one of two values"). pc.sv itself
// is unchanged.
//
// The PC computes next_pc in EXECUTE (core_state==3'b101) and latches the NZP
// flags from the ALU in UPDATE (core_state==3'b110). Proven invariants:
//
//   reset_state      : after reset, next_pc and nzp are zero.
//   seq_update       : a non-branch step (pc_mux==0) advances next_pc = pc + 1.
//   branch_taken     : a BRnzp (pc_mux==1) whose NZP mask matches the latched
//                      flags jumps to the decoded immediate.
//   branch_nottaken  : a BRnzp whose mask does NOT match falls through to pc+1.
//   nzp_latch        : a CMP in UPDATE latches alu_out[2:0] into nzp.
//   nzp_hold         : nzp only changes on a CMP-in-UPDATE step.
//   pc_hold          : next_pc only changes on an EXECUTE step.

`default_nettype none
`timescale 1ns/1ns

module pc_props #(
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8
) (
    input wire                              clk,
    input wire                              reset,
    input wire                              enable,
    input wire [2:0]                        core_state,
    input wire [2:0]                        decoded_nzp,
    input wire [DATA_MEM_DATA_BITS-1:0]     decoded_immediate,
    input wire                              decoded_nzp_write_enable,
    input wire                              decoded_pc_mux,
    input wire [DATA_MEM_DATA_BITS-1:0]     alu_out,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0]  current_pc,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0]  next_pc,
    input wire [2:0]                        nzp        // white-box internal probe
);

    localparam [2:0] EXECUTE = 3'b101,
                     UPDATE  = 3'b110;

    // One-cycle history shadows.
    reg                              past_valid;
    reg                              past_reset;
    reg                              past_enable;
    reg [2:0]                        past_core_state;
    reg [2:0]                        past_decoded_nzp;
    reg [DATA_MEM_DATA_BITS-1:0]     past_decoded_immediate;
    reg                              past_decoded_nzp_write_enable;
    reg                              past_decoded_pc_mux;
    reg [DATA_MEM_DATA_BITS-1:0]     past_alu_out;
    reg [PROGRAM_MEM_ADDR_BITS-1:0]  past_current_pc;
    reg [PROGRAM_MEM_ADDR_BITS-1:0]  past_next_pc;
    reg [2:0]                        past_nzp;

    initial begin
        past_valid                    = 1'b0;
        past_reset                    = 1'b1;
        past_enable                   = 1'b0;
        past_core_state               = 3'b0;
        past_decoded_nzp              = 3'b0;
        past_decoded_immediate        = '0;
        past_decoded_nzp_write_enable = 1'b0;
        past_decoded_pc_mux           = 1'b0;
        past_alu_out                  = '0;
        past_current_pc               = '0;
        past_next_pc                  = '0;
        past_nzp                      = 3'b0;
    end

    always @(posedge clk) begin
        past_valid                    <= 1'b1;
        past_reset                    <= reset;
        past_enable                   <= enable;
        past_core_state               <= core_state;
        past_decoded_nzp              <= decoded_nzp;
        past_decoded_immediate        <= decoded_immediate;
        past_decoded_nzp_write_enable <= decoded_nzp_write_enable;
        past_decoded_pc_mux           <= decoded_pc_mux;
        past_alu_out                  <= alu_out;
        past_current_pc               <= current_pc;
        past_next_pc                  <= next_pc;
        past_nzp                      <= nzp;
    end

    // The PC flops have no initial value, so constrain the harness to begin in
    // reset (mirrors the per-block reset the core always pulses first).
    always @(*) begin
        if (!past_valid) begin
            assume (reset);
        end
    end

    always @(posedge clk) begin
        if (past_valid) begin
            // reset_state: a reset cycle clears next_pc and the NZP register.
            if (past_reset) begin
                assert (next_pc == '0);
                assert (nzp == 3'b0);
            end

            // ---- next_pc computation (only in EXECUTE while enabled) --------
            if (!past_reset && past_enable && past_core_state == EXECUTE) begin
                if (!past_decoded_pc_mux) begin
                    // seq_update: non-branch advances sequentially.
                    assert (next_pc == past_current_pc + 1'b1);
                end else if ((past_nzp & past_decoded_nzp) != 3'b0) begin
                    // branch_taken: matching BRnzp jumps to the immediate.
                    assert (next_pc == past_decoded_immediate);
                end else begin
                    // branch_nottaken: non-matching BRnzp falls through.
                    assert (next_pc == past_current_pc + 1'b1);
                end
            end

            // pc_hold: outside an enabled EXECUTE step, next_pc is unchanged.
            if (!past_reset && !(past_enable && past_core_state == EXECUTE)) begin
                assert (next_pc == past_next_pc);
            end

            // ---- NZP register (latched in UPDATE on a CMP) ------------------
            // nzp_latch: a CMP in UPDATE captures alu_out[2:0].
            if (!past_reset && past_enable && past_core_state == UPDATE
                && past_decoded_nzp_write_enable) begin
                assert (nzp == past_alu_out[2:0]);
            end

            // nzp_hold: nzp only changes on an enabled CMP-in-UPDATE step.
            if (!past_reset && !(past_enable && past_core_state == UPDATE
                                 && past_decoded_nzp_write_enable)) begin
                assert (nzp == past_nzp);
            end
        end
    end

endmodule
