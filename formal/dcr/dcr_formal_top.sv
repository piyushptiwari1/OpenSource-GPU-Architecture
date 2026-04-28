// Formal top: instantiates DCR as DUT and binds the property module.
// Used by SymbiYosys (formal/dcr/dcr.sby).

`default_nettype none

module dcr_formal_top (
    input wire       clk,
    input wire       reset,
    input wire       device_control_write_enable,
    input wire [7:0] device_control_data
);

    wire [7:0] thread_count;

    dcr u_dcr (
        .clk(clk),
        .reset(reset),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

    dcr_props u_props (
        .clk(clk),
        .reset(reset),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

endmodule
