// Formal top: instantiates the ALU as DUT and binds the property module.
// Used by SymbiYosys (formal/alu/alu.sby).
//
// Every ALU input is exposed as a free top-level port, so the engine drives
// them as unconstrained symbolic stimulus; the property module only observes
// the registered output and checks it against the spec.

`default_nettype none
`timescale 1ns/1ns

module alu_formal_top (
    input wire        clk,
    input wire        reset,
    input wire        enable,
    input wire [2:0]  core_state,
    input wire [1:0]  decoded_alu_arithmetic_mux,
    input wire        decoded_alu_output_mux,
    input wire [7:0]  rs,
    input wire [7:0]  rt
);

    wire [7:0] alu_out;

    alu u_alu (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .core_state(core_state),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .rs(rs),
        .rt(rt),
        .alu_out(alu_out)
    );

    alu_props u_props (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .core_state(core_state),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .rs(rs),
        .rt(rt),
        .alu_out(alu_out)
    );

endmodule
