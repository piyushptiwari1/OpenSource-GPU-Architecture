// Formal top: instantiates the LSU as DUT and binds the property module.
// Used by SymbiYosys (formal/lsu/lsu.sby).
//
// All LSU inputs are exposed as top-level ports so the engine drives them as
// free symbolic stimulus; the property module only observes outputs (and
// constrains the decode/enable inputs with the documented env contract).

`default_nettype none
`timescale 1ns/1ns

module lsu_formal_top (
    input wire       clk,
    input wire       reset,
    input wire       enable,
    input wire [2:0] core_state,
    input wire       decoded_mem_read_enable,
    input wire       decoded_mem_write_enable,
    input wire       decoded_atomic_op,
    input wire       decoded_shared,
    input wire [7:0] rs,
    input wire [7:0] rt,
    input wire       mem_read_ready,
    input wire [7:0] mem_read_data,
    input wire       mem_write_ready,
    input wire       shared_read_ready,
    input wire [7:0] shared_read_data,
    input wire       shared_write_ready
);

    wire       mem_read_valid;
    wire [7:0] mem_read_address;
    wire       mem_write_valid;
    wire [7:0] mem_write_address;
    wire [7:0] mem_write_data;
    wire       shared_read_valid;
    wire [7:0] shared_read_address;
    wire       shared_write_valid;
    wire [7:0] shared_write_address;
    wire [7:0] shared_write_data;
    wire [1:0] lsu_state;
    wire [7:0] lsu_out;
    wire       consumer_atomic;

    lsu u_lsu (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .core_state(core_state),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_atomic_op(decoded_atomic_op),
        .decoded_shared(decoded_shared),
        .rs(rs),
        .rt(rt),
        .mem_read_valid(mem_read_valid),
        .mem_read_address(mem_read_address),
        .mem_read_ready(mem_read_ready),
        .mem_read_data(mem_read_data),
        .mem_write_valid(mem_write_valid),
        .mem_write_address(mem_write_address),
        .mem_write_data(mem_write_data),
        .mem_write_ready(mem_write_ready),
        .shared_read_valid(shared_read_valid),
        .shared_read_address(shared_read_address),
        .shared_read_ready(shared_read_ready),
        .shared_read_data(shared_read_data),
        .shared_write_valid(shared_write_valid),
        .shared_write_address(shared_write_address),
        .shared_write_data(shared_write_data),
        .shared_write_ready(shared_write_ready),
        .lsu_state(lsu_state),
        .lsu_out(lsu_out),
        .consumer_atomic(consumer_atomic)
    );

    lsu_props u_props (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .core_state(core_state),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_atomic_op(decoded_atomic_op),
        .decoded_shared(decoded_shared),
        .lsu_state(lsu_state),
        .mem_read_valid(mem_read_valid),
        .mem_read_address(mem_read_address),
        .mem_read_ready(mem_read_ready),
        .mem_write_valid(mem_write_valid),
        .mem_write_address(mem_write_address),
        .mem_write_data(mem_write_data),
        .mem_write_ready(mem_write_ready),
        .shared_read_valid(shared_read_valid),
        .shared_read_address(shared_read_address),
        .shared_read_ready(shared_read_ready),
        .shared_write_valid(shared_write_valid),
        .shared_write_address(shared_write_address),
        .shared_write_ready(shared_write_ready)
    );

endmodule
