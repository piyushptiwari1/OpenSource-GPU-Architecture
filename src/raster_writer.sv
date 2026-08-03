`default_nettype none
`timescale 1ns/1ns

// RASTER WRITER
// > Streams the fixed-function rasterizer's pixel output into global data
//   memory as an ordinary memory-controller consumer (one extra consumer
//   port beside the SIMT lanes' LSUs).
// > Pixel (x, y) lands at FB_BASE + y * 2^FB_WIDTH_LOG2 + x, so the
//   framebuffer is a row-major window of data memory that kernels can read
//   back with plain LDRs - the writes flow through the same controller and
//   write-through L2 as every other memory access, which is exactly what
//   keeps the fixed-function and programmable engines coherent.
module raster_writer #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8,
    parameter COORD_BITS = 8,
    parameter FB_BASE = 64,        // first framebuffer address
    parameter FB_WIDTH_LOG2 = 3    // row stride = 8 pixels
) (
    input wire clk,
    input wire reset,

    // Pixel stream from the rasterizer.
    input wire pixel_valid,
    input wire [COORD_BITS-1:0] pixel_x,
    input wire [COORD_BITS-1:0] pixel_y,
    input wire [DATA_BITS-1:0] pixel_color,
    output reg pixel_ack,

    // Data-memory consumer port (write-only; the read side is tied off at
    // the GPU top).
    output reg mem_write_valid,
    output reg [ADDR_BITS-1:0] mem_write_address,
    output reg [DATA_BITS-1:0] mem_write_data,
    input wire mem_write_ready,

    // High while a pixel is buffered or a write is in flight; the GPU top
    // ORs this into raster_busy so "not busy" really means "every rendered
    // pixel has been committed to memory".
    output wire busy
);
    localparam IDLE = 1'b0, WRITE = 1'b1;
    reg state;

    assign busy = (state != IDLE) || pixel_valid;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            pixel_ack <= 0;
            mem_write_valid <= 0;
            mem_write_address <= {ADDR_BITS{1'b0}};
            mem_write_data <= {DATA_BITS{1'b0}};
        end else begin
            // pixel_ack is a one-cycle pulse (the rasterizer drops
            // pixel_valid on the ack edge).
            pixel_ack <= 0;

            case (state)
                IDLE: begin
                    if (pixel_valid && !pixel_ack) begin
                        // Latch the pixel, ack the rasterizer, and issue the
                        // memory write. The arithmetic truncates into
                        // ADDR_BITS (the framebuffer window is expected to
                        // fit; out-of-window primitives simply wrap).
                        mem_write_address <= FB_BASE[ADDR_BITS-1:0]
                            + (pixel_y << FB_WIDTH_LOG2) + pixel_x;
                        mem_write_data <= pixel_color;
                        mem_write_valid <= 1;
                        pixel_ack <= 1;
                        state <= WRITE;
                    end
                end
                WRITE: begin
                    // Hold the request until the controller acks, then drop
                    // valid (the controller's relay state waits for exactly
                    // that falling edge).
                    if (mem_write_ready) begin
                        mem_write_valid <= 0;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule
