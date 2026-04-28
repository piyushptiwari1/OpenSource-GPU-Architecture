; vecadd: c[tid] = a[tid] + b[tid] for tid in [0, N).
;
; Memory layout (N = block_dim, set by host via DCR / refsim --threads):
;   [0,        N)   : input a
;   [N,       2N)   : input b
;   [2N,      3N)   : output c
;
; This benchmark is launched with one block of N threads (default N=4).
; Each thread computes one element. Uses %threadIdx (R15) verbatim, so the
; same .asm runs unchanged for any N <= 16 (memory size permitting).

  CONST R3, #0          ; a_base
  CONST R4, #4          ; b_base = N
  CONST R5, #8          ; c_base = 2N
  ADD   R6, R3, R15     ; addr_a = a_base + tid
  ADD   R7, R4, R15     ; addr_b = b_base + tid
  ADD   R8, R5, R15     ; addr_c = c_base + tid
  LDR   R9,  R6         ; a[tid]
  LDR   R10, R7         ; b[tid]
  ADD   R11, R9, R10    ; sum
  STR   R8, R11         ; c[tid] = sum
  RET
