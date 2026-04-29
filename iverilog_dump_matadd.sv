module iverilog_dump_matadd();
initial begin
    $dumpfile("matadd.vcd");
    $dumpvars(0, gpu);
end
endmodule
