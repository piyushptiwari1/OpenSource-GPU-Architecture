import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# L1 instruction-cache end-to-end test.
#
# Runs the standard 2x2 matmul kernel (which contains a loop, so the same
# program addresses are fetched repeatedly) and asserts the architectural
# properties of the per-core instruction cache:
#
#   1. The kernel result is still correct (cache is transparent).
#   2. Loop re-fetches are served from the cache: perf_icache_hit_count > 0.
#   3. Only cache MISSES reach external program memory: the number of read
#      transactions observed on the top-level program-memory bus equals
#      perf_icache_miss_count. This is the whole point of the cache - loop
#      bodies stop consuming external fetch bandwidth.
@cocotb.test()
async def test_icache_e2e(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # MUL R0, %blockIdx, %blockDim
        0b0011000000001111,  # ADD R0, R0, %threadIdx
        0b1001000100000001,  # CONST R1, #1
        0b1001001000000010,  # CONST R2, #2
        0b1001001100000000,  # CONST R3, #0
        0b1001010000000100,  # CONST R4, #4
        0b1001010100001000,  # CONST R5, #8
        0b0110011000000010,  # DIV R6, R0, R2
        0b0101011101100010,  # MUL R7, R6, R2
        0b0100011100000111,  # SUB R7, R0, R7
        0b1001100000000000,  # CONST R8, #0
        0b1001100100000000,  # CONST R9, #0
        0b0101101001100010,  # LOOP: MUL R10, R6, R2
        0b0011101010101001,  #   ADD R10, R10, R9
        0b0011101010100011,  #   ADD R10, R10, R3
        0b0111101010100000,  #   LDR R10, R10
        0b0101101110010010,  #   MUL R11, R9, R2
        0b0011101110110111,  #   ADD R11, R11, R7
        0b0011101110110100,  #   ADD R11, R11, R4
        0b0111101110110000,  #   LDR R11, R11
        0b0101110010101011,  #   MUL R12, R10, R11
        0b0011100010001100,  #   ADD R8, R8, R12
        0b0011100110010001,  #   ADD R9, R9, R1
        0b0010000010010010,  #   CMP R9, R2
        0b0001100000001100,  #   BRn LOOP
        0b0011100101010000,  # ADD R9, R5, R0
        0b1000000010011000,  # STR R9, R8
        0b1111000000000000,  # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        1, 2, 3, 4,  # Matrix A (2 x 2)
        1, 2, 3, 4,  # Matrix B (2 x 2)
    ]

    threads = 4

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    # Count read transactions actually served by external program memory.
    # A transaction completes on a cycle where valid and ready are both high
    # (PROGRAM_MEM_NUM_CHANNELS = 1, so these are single-bit signals).
    program_mem_beats = 0

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)
        if int(dut.program_mem_read_valid.value) == 1 and int(dut.program_mem_read_ready.value) == 1:
            program_mem_beats += 1

        await RisingEdge(dut.clk)
        cycles += 1

    # Let the registered top-level aggregation latch the cores' final counts.
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # 1. Functional result must be correct (cache is architecturally invisible).
    matrix_a = [data[0:2], data[2:4]]
    matrix_b = [data[4:6], data[6:8]]
    expected_results = [
        matrix_a[0][0] * matrix_b[0][0] + matrix_a[0][1] * matrix_b[1][0],
        matrix_a[0][0] * matrix_b[0][1] + matrix_a[0][1] * matrix_b[1][1],
        matrix_a[1][0] * matrix_b[0][0] + matrix_a[1][1] * matrix_b[1][0],
        matrix_a[1][0] * matrix_b[0][1] + matrix_a[1][1] * matrix_b[1][1],
    ]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 8]
        assert result == expected, (
            f"Result mismatch at index {i}: expected {expected}, got {result}"
        )

    icache_hits = int(dut.perf_icache_hit_count.value)
    icache_misses = int(dut.perf_icache_miss_count.value)
    instr_count = int(dut.perf_instr_count.value)

    logger.info(
        f"icache: hits={icache_hits} misses={icache_misses} "
        f"program_mem_beats={program_mem_beats} instrs={instr_count} cycles={cycles}"
    )

    # 2. The loop body is fetched more than once; re-fetches must hit in cache.
    assert icache_hits > 0, "expected loop re-fetches to hit in the instruction cache"

    # 3. Only misses reach external program memory. This is the bandwidth
    #    reduction the cache exists to provide.
    assert program_mem_beats == icache_misses, (
        f"external program memory saw {program_mem_beats} reads but the icache "
        f"recorded {icache_misses} misses - the cache should be the only "
        f"consumer of external fetch bandwidth"
    )

    # 4. Sanity: cold misses cannot exceed the program footprint by more than
    #    the speculative-fetch overrun margin.
    assert icache_misses <= len(program) + 8, (
        f"unexpectedly high miss count {icache_misses} for a "
        f"{len(program)}-instruction program"
    )
