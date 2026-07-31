import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# L2 data-cache end-to-end test.
#
# The banked write-through L2 sits between the data memory controller and
# external memory. This kernel generates guaranteed TEMPORAL reuse: every
# thread loads the same table entry table[threadIdx] four times in a loop
# (distinct addresses across lanes, so the warp coalescer provably cannot
# collapse them - each LDR reaches the L2 as its own transaction).
#
# Asserted architectural invariants:
#   1. Results are correct (the cache is transparent).
#   2. hits + misses == total LDRs issued (32) - every upstream read passes
#      through the L2 exactly once.
#   3. hits > 0 - the loop re-reads are served on-chip.
#   4. External read transactions == l2_miss_count - only misses spend
#      external bandwidth. This is the point of the cache.
#   5. External write transactions == total STRs (8) - write-through sends
#      every store to external memory, keeping it authoritative.
#
# Kernel (PC : instruction):
#   0  MUL   R0, %blockIdx, %blockDim
#   1  ADD   R0, R0, %threadIdx        ; i = global thread index
#   2  CONST R1, #1                    ; increment
#   3  CONST R2, #4                    ; loop bound
#   4  CONST R3, #0                    ; acc = 0
#   5  CONST R4, #0                    ; k = 0
#   6  LDR   R5, %threadIdx            ; LOOP: load table[threadIdx]
#   7  ADD   R3, R3, R5                ;   acc += table[tid]
#   8  ADD   R4, R4, R1                ;   k++
#   9  CMP   R4, R2
#   10 BRn   6                         ; while k < 4
#   11 CONST R6, #16
#   12 ADD   R6, R6, R0                ; &out[i]
#   13 STR   R6, R3                    ; out[i] = acc
#   14 RET
@cocotb.test()
async def test_l2_cache_e2e(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
        0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx
        0b1001000100000001,  # 2  CONST R1, #1
        0b1001001000000100,  # 3  CONST R2, #4
        0b1001001100000000,  # 4  CONST R3, #0
        0b1001010000000000,  # 5  CONST R4, #0
        0b0111010111110000,  # 6  LDR   R5, %threadIdx
        0b0011001100110101,  # 7  ADD   R3, R3, R5
        0b0011010001000001,  # 8  ADD   R4, R4, R1
        0b0010000001000010,  # 9  CMP   R4, R2
        0b0001100000000110,  # 10 BRn   6
        0b1001011000010000,  # 11 CONST R6, #16
        0b0011011001100000,  # 12 ADD   R6, R6, R0
        0b1000000001100011,  # 13 STR   R6, R3
        0b1111000000000000,  # 14 RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    table = [5, 7, 9, 11]
    data = table + [0] * 28  # table at 0..3, out region at 16..23

    threads = 8       # 2 blocks of blockDim = 4
    loop_count = 4
    total_loads = threads * loop_count   # 32 - coalescer cannot collapse any
    total_stores = threads               # 8

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    # Count completed transactions on the EXTERNAL data-memory bus
    # (valid & ready handshakes per channel per cycle).
    ext_read_beats = 0
    ext_write_beats = 0

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        rv = int(dut.data_mem_read_valid.value)
        rr = int(dut.data_mem_read_ready.value)
        wv = int(dut.data_mem_write_valid.value)
        wr = int(dut.data_mem_write_ready.value)
        ext_read_beats += bin(rv & rr).count("1")
        ext_write_beats += bin(wv & wr).count("1")

        await RisingEdge(dut.clk)
        cycles += 1
        assert cycles < 20000, "kernel did not finish"

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # 1. Functional correctness: out[i] = 4 * table[i % 4].
    for i in range(threads):
        expected = loop_count * table[i % 4]
        result = data_memory.memory[16 + i]
        assert result == expected, (
            f"out[{i}]: expected {expected}, got {result}"
        )

    l2_hits = int(dut.perf_l2_hit_count.value)
    l2_misses = int(dut.perf_l2_miss_count.value)

    logger.info(
        f"l2: hits={l2_hits} misses={l2_misses} "
        f"ext_read_beats={ext_read_beats} ext_write_beats={ext_write_beats} "
        f"cycles={cycles}"
    )

    # 2. Every LDR passes through the L2 exactly once.
    assert l2_hits + l2_misses == total_loads, (
        f"L2 saw {l2_hits}+{l2_misses} reads, expected exactly {total_loads}"
    )

    # 3. Temporal reuse must be served on-chip.
    assert l2_hits > 0, "loop re-reads should hit in the L2"

    # 4. Only misses reach external memory.
    assert ext_read_beats == l2_misses, (
        f"external memory saw {ext_read_beats} reads but the L2 recorded "
        f"{l2_misses} misses - misses must be the only external read traffic"
    )

    # 5. Write-through: every store reaches external memory.
    assert ext_write_beats == total_stores, (
        f"external memory saw {ext_write_beats} writes, expected exactly "
        f"{total_stores} (write-through forwards every store)"
    )
