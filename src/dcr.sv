`default_nettype none
`timescale 1ns/1ns

// DEVICE CONTROL REGISTER
// > Used to configure high-level GPU launch settings.
// > In this minimal example, the DCR only stores one thing: the total number of threads
//   that should be launched for the next kernel.
// > Beginner mental model:
//   software/testbench writes one 8-bit value here, and the dispatcher later reads it.
//
// Beginner notes:
// 1. This is the simplest possible "config register" module: on the clock edge it
//    latches whatever the outside world wrote in.
// 2. In Verilog, `input` / `output` describe port direction, and `[7:0]` means the
//    port is 8 bits wide.
// 3. `assign thread_count = ...` is a continuous assignment: it directly wires bits
//    from the internal register out to the port.
// 4. There is no complex protocol; the single `device_control_write_enable` strobe,
//    when high on a clock edge, latches `device_control_data`.
module dcr (
    input wire clk,
    input wire reset,

    // Simple write interface from the outside world / testbench.
    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // Current configured total thread count for the kernel launch.
    output wire [7:0] thread_count
);
    // Internal storage register for the device control data.
    // `reg [7:0]` declares an 8-bit storage variable that holds state across clocks.
    reg [7:0] device_control_register;

    // No clock involved here: this is combinational wiring, so `thread_count`
    // always equals the current value of the internal register.
    assign thread_count = device_control_register[7:0];

    always @(posedge clk) begin
        if (reset) begin
            // Reset clears the launch configuration.
            device_control_register <= 8'b0;
        end else begin
            if (device_control_write_enable) begin
                // Latch the new launch configuration when write_enable is high.
                // The non-blocking assignment `<=` writes the input data into the
                // internal register on this rising edge.
                device_control_register <= device_control_data;
            end
        end
    end
endmodule
`default_nettype none
`timescale 1ns/1ns

// DEVICE CONTROL REGISTER
// > Used to configure high-level settings
// > In this minimal example, the DCR is used to configure the number of threads to run for the kernel
module dcr (
    input wire clk,
    input wire reset,

    input wire device_control_write_enable,
    input wire [7:0] device_control_data,
    output wire [7:0] thread_count
);
    // Store device control data in dedicated register
    reg [7:0] device_control_register;
    assign thread_count = device_control_register[7:0];

    always @(posedge clk) begin
        if (reset) begin
            device_control_register <= 8'b0;
        end else begin
            if (device_control_write_enable) begin 
                device_control_register <= device_control_data;
            end
        end
    end
endmodule