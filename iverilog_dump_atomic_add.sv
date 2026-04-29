module iverilog_dump_atomic_add();
initial begin
    $dumpfile("atomic_add.vcd");
    $dumpvars(0, gpu);
end
endmodule
