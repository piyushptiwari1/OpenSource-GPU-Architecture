"""scalar_inc benchmark wiring."""

from __future__ import annotations

N = 1
BLOCKS = 1
MEM_SIZE = 16


def input_data() -> list[int]:
    return [0] * MEM_SIZE


def golden(initial: list[int]) -> dict[int, int]:
    # Kernel writes 0xCA to mem[0].
    return {0: 0xCA}
