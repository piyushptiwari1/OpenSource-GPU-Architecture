// Formal top: instantiates the FETCHER as DUT and binds the property module.
// Used by SymbiYosys (formal/fetcher/fetcher.sby).
//
// All fetcher inputs are exposed as top-level ports so the engine drives them
// as free symbolic stimulus; the property module only observes outputs.

`default_nettype none
`timescale 1ns/1ns

module fetcher_formal_top #(
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16
) (
    input wire                              clk,
    input wire                              reset,
    input wire [2:0]                        core_state,
    input wire [7:0]                        current_pc,
    input wire                              mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0]  mem_read_data
);

    wire                              mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0]  mem_read_address;
    wire [2:0]                        fetcher_state;
    wire [PROGRAM_MEM_DATA_BITS-1:0]  instruction;

    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) u_fetcher (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .current_pc(current_pc),
        .mem_read_valid(mem_read_valid),
        .mem_read_address(mem_read_address),
        .mem_read_ready(mem_read_ready),
        .mem_read_data(mem_read_data),
        .fetcher_state(fetcher_state),
        .instruction(instruction)
    );

    fetcher_props #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) u_props (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .fetcher_state(fetcher_state),
        .mem_read_valid(mem_read_valid),
        .mem_read_address(mem_read_address),
        .mem_read_ready(mem_read_ready)
    );

endmodule
