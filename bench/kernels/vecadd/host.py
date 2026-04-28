"""vecadd benchmark wiring (4-element, single block)."""

from __future__ import annotations

N = 4
BLOCKS = 1
MEM_SIZE = 32  # 3*N + slack

# Deterministic, non-trivial inputs that exercise the 8-bit add (no overflow).
A = [10, 20, 30, 40]
B = [1, 2, 3, 4]


def input_data() -> list[int]:
    mem = [0] * MEM_SIZE
    for i, v in enumerate(A):
        mem[i] = v & 0xFF
    for i, v in enumerate(B):
        mem[N + i] = v & 0xFF
    return mem


def golden(initial: list[int]) -> dict[int, int]:
    out: dict[int, int] = {}
    for i in range(N):
        out[2 * N + i] = (A[i] + B[i]) & 0xFF
    return out
