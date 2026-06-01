// Formal properties for the ARITHMETIC-LOGIC UNIT result correctness.
//
// Wired in via formal/alu/alu_formal_top.sv; never perturbs the synthesizable
// RTL. Verified with yosys + yices2 (SymbiYosys, k-induction).
//
// Style mirrors dcr_props.sv: immediate `assert` inside a clocked block with
// manual one-cycle history shadows (`past_*`). The ALU latches its result in
// EXECUTE (core_state==3'b101) while enabled, so every check compares the
// registered `alu_out` against the spec computed from the *previous* cycle's
// operands -- a self-checking reference-model proof.
//
// Proven invariants
// -----------------
//   reset_state : after reset, alu_out is zero.
//   cmp_result  : an enabled EXECUTE with output_mux==1 yields the NZP compare
//                 word {5'b0, rs<rt, rs==rt, rs>rt} (used by the BRnzp path).
//   add_result  : an enabled EXECUTE, output_mux==0, ADD  -> alu_out == rs + rt.
//   sub_result  :                                     SUB  -> alu_out == rs - rt.
//   mul_result  :                                     MUL  -> alu_out == rs * rt.
//   div_result  :                                     DIV  -> alu_out == rs / rt
//                 (guarded rt != 0; division by zero is left unconstrained, as
//                 the RTL itself is, and never occurs in the verified kernels).
//   out_hold    : outside an enabled EXECUTE step, alu_out is unchanged.

`default_nettype none
`timescale 1ns/1ns

module alu_props (
    input wire        clk,
    input wire        reset,
    input wire        enable,
    input wire [2:0]  core_state,
    input wire [1:0]  decoded_alu_arithmetic_mux,
    input wire        decoded_alu_output_mux,
    input wire [7:0]  rs,
    input wire [7:0]  rt,
    input wire [7:0]  alu_out
);

    localparam [2:0] EXECUTE = 3'b101;
    localparam [1:0] ADD = 2'b00, SUB = 2'b01, MUL = 2'b10, DIV = 2'b11;

    // One-cycle history shadows.
    reg        past_valid;
    reg        past_reset;
    reg        past_enable;
    reg [2:0]  past_core_state;
    reg [1:0]  past_arith_mux;
    reg        past_output_mux;
    reg [7:0]  past_rs;
    reg [7:0]  past_rt;
    reg [7:0]  past_alu_out;

    initial begin
        past_valid      = 1'b0;
        past_reset      = 1'b1;
        past_enable     = 1'b0;
        past_core_state = 3'b0;
        past_arith_mux  = 2'b0;
        past_output_mux = 1'b0;
        past_rs         = 8'b0;
        past_rt         = 8'b0;
        past_alu_out    = 8'b0;
    end

    always @(posedge clk) begin
        past_valid      <= 1'b1;
        past_reset      <= reset;
        past_enable     <= enable;
        past_core_state <= core_state;
        past_arith_mux  <= decoded_alu_arithmetic_mux;
        past_output_mux <= decoded_alu_output_mux;
        past_rs         <= rs;
        past_rt         <= rt;
        past_alu_out    <= alu_out;
    end

    // The result register has no initial value, so constrain the harness to
    // begin in reset (mirrors the per-block reset the core always pulses first).
    always @(*) begin
        if (!past_valid) begin
            assume (reset);
        end
    end

    always @(posedge clk) begin
        if (past_valid) begin
            // reset_state: a reset cycle clears the result.
            if (past_reset) begin
                assert (alu_out == 8'b0);
            end

            // ---- result computation (enabled EXECUTE) ----------------------
            if (!past_reset && past_enable && past_core_state == EXECUTE) begin
                if (past_output_mux) begin
                    // cmp_result: NZP compare word.
                    assert (alu_out ==
                        {5'b0, (past_rs < past_rt),
                               (past_rs == past_rt),
                               (past_rs > past_rt)});
                end else begin
                    unique case (past_arith_mux)
                        ADD: assert (alu_out == (past_rs + past_rt));
                        SUB: assert (alu_out == (past_rs - past_rt));
                        MUL: assert (alu_out == (past_rs * past_rt));
                        DIV: if (past_rt != 8'b0)
                                 assert (alu_out == (past_rs / past_rt));
                    endcase
                end
            end

            // out_hold: outside an enabled EXECUTE step, alu_out is unchanged.
            if (!past_reset && !(past_enable && past_core_state == EXECUTE)) begin
                assert (alu_out == past_alu_out);
            end
        end
    end

endmodule
