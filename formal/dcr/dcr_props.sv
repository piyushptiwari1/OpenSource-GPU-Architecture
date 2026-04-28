// Formal properties for the DCR (device control register).
//
// Wired in via formal/dcr/dcr_formal_top.sv so we don't perturb the
// synthesizable RTL. Verified with yosys-smtbmc + yices2 in BMC mode.
//
// Style: yosys' default formal frontend supports immediate ``assert``
// statements inside ``always`` blocks but not module-scope concurrent
// ``assert property``. We track the previous-cycle values manually via
// flop-shadows (``past_*``) so all assertions are pure combinational.
//
// Properties proven here
// ----------------------
//   reset_clears   : one cycle after reset, thread_count is 0.
//   strobe_latches : after write_enable is high, thread_count equals the
//                    data that was on data_in last cycle.
//   no_write_hold  : if write_enable was low last cycle and we were not
//                    in reset, thread_count is unchanged.

`default_nettype none

module dcr_props (
    input wire        clk,
    input wire        reset,
    input wire        device_control_write_enable,
    input wire [7:0]  device_control_data,
    input wire [7:0]  thread_count
);

    // One-cycle history.
    reg        past_valid;
    reg        past_reset;
    reg        past_we;
    reg [7:0]  past_data;
    reg [7:0]  past_thread_count;

    initial begin
        past_valid        = 1'b0;
        past_reset        = 1'b1;
        past_we           = 1'b0;
        past_data         = 8'h00;
        past_thread_count = 8'h00;
    end

    always @(posedge clk) begin
        past_valid        <= 1'b1;
        past_reset        <= reset;
        past_we           <= device_control_write_enable;
        past_data         <= device_control_data;
        past_thread_count <= thread_count;
    end

    always @(posedge clk) begin
        if (past_valid) begin
            // reset_clears: after a reset cycle, output is 0.
            if (past_reset) begin
                assert (thread_count == 8'h00);
            end

            // strobe_latches: write_enable propagates last-cycle data.
            if (!past_reset && past_we) begin
                assert (thread_count == past_data);
            end

            // no_write_hold: stale value preserved when write was low.
            if (!past_reset && !past_we) begin
                assert (thread_count == past_thread_count);
            end
        end
    end

endmodule
