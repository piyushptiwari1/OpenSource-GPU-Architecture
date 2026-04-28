"""Benchmark configurations.

Each kernel directory under ``bench/kernels/<name>/`` ships a ``kernel.asm``
and a Python sibling defining:

- ``N``: number of threads in a block (== ``--threads`` for refsim)
- ``BLOCKS``: number of blocks (== ``--blocks``)
- ``MEM_SIZE``: bytes of unified memory the kernel needs
- ``input_data() -> list[int]``: initial memory contents (length <= MEM_SIZE)
- ``golden(initial: list[int]) -> dict[int, int]``: expected ``addr -> value``
  mapping for **bytes the kernel is required to produce**. Other bytes are
  not checked, so reordering of the address space stays a host concern.
"""
