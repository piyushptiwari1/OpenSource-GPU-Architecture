; scalar_inc: single-threaded smoke benchmark.
; Writes 0xCA to mem[0]. Used to check the bench harness end-to-end.
CONST R0, #0
CONST R1, #0xCA
STR   R0, R1
RET
