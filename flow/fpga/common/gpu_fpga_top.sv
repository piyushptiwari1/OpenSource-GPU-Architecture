// Synthesizable FPGA top-level for tiny-gpu.
//
// The original `gpu` module exposes external program/data memory ports
// using SystemVerilog unpacked arrays, which is exactly what you want
// in a testbench but inconvenient on a board.  This wrapper:
//
//   * Instantiates `gpu` with a minimum-area config (NUM_CORES=1,
//     THREADS_PER_BLOCK=2) so it fits on small dev boards
//     (iCE40HX8K, ECP5-25F).
//   * Adds inferable block-RAM for program and data memory, preloaded
//     with hex files via $readmemh.  Vendor primitive inference is left
//     to yosys (`synth_ice40 -abc9` / `synth_ecp5`), which picks SB_RAM
//     or DP16KD as appropriate.
//   * Drives a simple 4-LED status output: {start, done, busy, heart}.
//
// Bitstream-flashing instructions live in flow/fpga/{ice40,ecp5}/README.

`default_nettype none
`timescale 1ns / 1ns

module gpu_fpga_top #(
    parameter PROG_HEX = "flow/fpga/programs/matadd_min.hex",
    parameter DATA_HEX = "flow/fpga/programs/matadd_min_data.hex"
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       button_start,
    output wire [3:0] led
);
    // ---- reset synchronizer (active high to gpu) -----------------------
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 2'b11;
        else        rst_sync <= {rst_sync[0], 1'b0};
    end
    wire reset = rst_sync[1];

    // ---- start debouncer (one-shot on button press) --------------------
    reg [15:0] debounce;
    reg        start_lat;
    reg        start_pulse;
    always @(posedge clk) begin
        if (reset) begin
            debounce    <= 0;
            start_lat   <= 0;
            start_pulse <= 0;
        end else begin
            debounce    <= {debounce[14:0], button_start};
            start_pulse <= (&debounce) & ~start_lat;
            start_lat   <= (&debounce);
        end
    end

    // ---- gpu instance with embedded memories ---------------------------
    localparam ADDR_BITS    = 8;
    localparam DATA_BITS    = 8;
    localparam INSTR_BITS   = 16;
    localparam NUM_CHANNELS_DATA = 1;
    localparam NUM_CHANNELS_PROG = 1;

    // Program memory (embedded, preloaded).
    reg [INSTR_BITS-1:0] prog_mem [(1<<ADDR_BITS)-1:0];
    initial $readmemh(PROG_HEX, prog_mem);

    // Data memory (embedded, preloaded).
    reg [DATA_BITS-1:0] data_mem [(1<<ADDR_BITS)-1:0];
    initial $readmemh(DATA_HEX, data_mem);

    // Program memory request/response.
    wire [NUM_CHANNELS_PROG-1:0]                prog_rd_valid;
    wire [ADDR_BITS-1:0]                        prog_rd_addr  [NUM_CHANNELS_PROG-1:0];
    reg  [NUM_CHANNELS_PROG-1:0]                prog_rd_ready;
    reg  [INSTR_BITS-1:0]                       prog_rd_data  [NUM_CHANNELS_PROG-1:0];

    // Data memory request/response.
    wire [NUM_CHANNELS_DATA-1:0]                d_rd_valid;
    wire [ADDR_BITS-1:0]                        d_rd_addr     [NUM_CHANNELS_DATA-1:0];
    reg  [NUM_CHANNELS_DATA-1:0]                d_rd_ready;
    reg  [DATA_BITS-1:0]                        d_rd_data     [NUM_CHANNELS_DATA-1:0];
    wire [NUM_CHANNELS_DATA-1:0]                d_wr_valid;
    wire [ADDR_BITS-1:0]                        d_wr_addr     [NUM_CHANNELS_DATA-1:0];
    wire [DATA_BITS-1:0]                        d_wr_data     [NUM_CHANNELS_DATA-1:0];
    reg  [NUM_CHANNELS_DATA-1:0]                d_wr_ready;

    // 1-cycle ready BRAM emulation: serve every accepted request the
    // following cycle.  Suitable for both single-port BRAM inference and
    // the gpu's request/response protocol.
    integer ch;
    always @(posedge clk) begin
        if (reset) begin
            prog_rd_ready <= 0;
            d_rd_ready    <= 0;
            d_wr_ready    <= 0;
        end else begin
            for (ch = 0; ch < NUM_CHANNELS_PROG; ch = ch + 1) begin
                prog_rd_ready[ch] <= prog_rd_valid[ch];
                if (prog_rd_valid[ch]) prog_rd_data[ch] <= prog_mem[prog_rd_addr[ch]];
            end
            for (ch = 0; ch < NUM_CHANNELS_DATA; ch = ch + 1) begin
                d_rd_ready[ch] <= d_rd_valid[ch];
                if (d_rd_valid[ch]) d_rd_data[ch] <= data_mem[d_rd_addr[ch]];

                d_wr_ready[ch] <= d_wr_valid[ch];
                if (d_wr_valid[ch]) data_mem[d_wr_addr[ch]] <= d_wr_data[ch];
            end
        end
    end

    wire done;
    gpu #(
        .DATA_MEM_ADDR_BITS       (ADDR_BITS),
        .DATA_MEM_DATA_BITS       (DATA_BITS),
        .DATA_MEM_NUM_CHANNELS    (NUM_CHANNELS_DATA),
        .PROGRAM_MEM_ADDR_BITS    (ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS    (INSTR_BITS),
        .PROGRAM_MEM_NUM_CHANNELS (NUM_CHANNELS_PROG),
        .NUM_CORES                (1),
        .THREADS_PER_BLOCK        (2)
    ) u_gpu (
        .clk                            (clk),
        .reset                          (reset),
        .start                          (start_pulse),
        .done                           (done),
        .device_control_write_enable    (start_pulse),
        .device_control_data            (8'd2),  // run 2 threads at boot

        .program_mem_read_valid         (prog_rd_valid),
        .program_mem_read_address       (prog_rd_addr),
        .program_mem_read_ready         (prog_rd_ready),
        .program_mem_read_data          (prog_rd_data),

        .data_mem_read_valid            (d_rd_valid),
        .data_mem_read_address          (d_rd_addr),
        .data_mem_read_ready            (d_rd_ready),
        .data_mem_read_data             (d_rd_data),
        .data_mem_write_valid           (d_wr_valid),
        .data_mem_write_address         (d_wr_addr),
        .data_mem_write_data            (d_wr_data),
        .data_mem_write_ready           (d_wr_ready)
    );

    // ---- LED indicators ------------------------------------------------
    reg [25:0] heartbeat;
    always @(posedge clk) heartbeat <= heartbeat + 1;

    reg busy;
    always @(posedge clk) begin
        if (reset)              busy <= 0;
        else if (start_pulse)   busy <= 1;
        else if (done)          busy <= 0;
    end

    assign led = {start_lat, done, busy, heartbeat[25]};
endmodule
