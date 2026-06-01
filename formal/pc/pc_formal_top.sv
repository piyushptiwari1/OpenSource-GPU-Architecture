// Formal top: instantiates the PROGRAM COUNTER as DUT and binds the property
// module. Used by SymbiYosys (formal/pc/pc.sby).
//
// All PC inputs are exposed as top-level ports so the engine drives them as
// free symbolic stimulus. The property module additionally observes the
// internal NZP register through a hierarchical reference (white-box), so the
// branch-target invariants can be proven exactly. pc.sv is unchanged.

`default_nettype none
`timescale 1ns/1ns

module pc_formal_top #(
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
    input wire [PROGRAM_MEM_ADDR_BITS-1:0]  current_pc
);

    wire [PROGRAM_MEM_ADDR_BITS-1:0] next_pc;

    pc #(
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
    ) u_pc (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .core_state(core_state),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),
        .decoded_pc_mux(decoded_pc_mux),
        .alu_out(alu_out),
        .current_pc(current_pc),
        .next_pc(next_pc)
    );

    pc_props #(
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
    ) u_props (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .core_state(core_state),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),
        .decoded_pc_mux(decoded_pc_mux),
        .alu_out(alu_out),
        .current_pc(current_pc),
        .next_pc(next_pc),
        .nzp(u_pc.nzp)   // white-box hierarchical reference to internal NZP reg
    );

endmodule
