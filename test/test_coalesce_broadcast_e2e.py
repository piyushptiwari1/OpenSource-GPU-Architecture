import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Warp same-address (broadcast) read-coalescing end-to-end test.
#
# Every lane in a block issues a LOAD from the SAME data-memory address (0).
# The per-core read coalescer must collapse those identical loads into a single
# memory transaction (one leader lane forwards the request, the rest are served
# from its result) and report the number of eliminated requests through the
# top-level `perf_coalesced_count` port.
#
# With THREADS_PER_BLOCK = 4 and 8 threads (2 full blocks), each block's 4 lanes
# share address 0, so 3 of every 4 loads are coalesced away per block:
#   eliminated = (THREADS_PER_BLOCK - 1) * num_blocks = 3 * 2 = 6.
#
# Functionally every lane stores the broadcast value mem[0] into mem[threadIdx],
# so the whole output region ends up equal to the seed value.
#
# Kernel (PC : instruction):
#   0  MUL   R0, %blockIdx, %blockDim
#   1  ADD   R0, R0, %threadIdx        ; R0 = global thread index i
#   2  CONST R1, #0                    ; broadcast load address (same for all lanes)
#   3  LDR   R2, R1                    ; R2 = mem[0]  <-- coalesced across the warp
#   4  STR   R0, R2                    ; mem[i] = R2
#   5  RET
@cocotb.test()
async def test_coalesce_broadcast(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
        0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx
        0b1001000100000000,  # 2  CONST R1, #0
        0b0111001000010000,  # 3  LDR   R2, R1
        0b1000000000000010,  # 4  STR   R0, R2
        0b1111000000000000,  # 5  RET
    ]

    seed = 42
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [seed, 0, 0, 0, 0, 0, 0, 0]

    threads = 8  # 2 blocks of blockDim = 4
    threads_per_block = 4
    num_blocks = threads // threads_per_block

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        await RisingEdge(dut.clk)
        cycles += 1

    # Let the registered top-level aggregation latch the final counts.
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # Every lane broadcast-loaded mem[0] and stored it to mem[threadIdx].
    for i in range(threads):
        result = data_memory.memory[i]
        assert result == seed, (
            f"Broadcast result mismatch at index {i}: expected {seed}, got {result}"
        )

    coalesced = int(dut.perf_coalesced_count.value)
    expected_coalesced = (threads_per_block - 1) * num_blocks

    logger.info(
        f"coalescing: eliminated={coalesced} read requests "
        f"(expected {expected_coalesced})"
    )

    assert coalesced == expected_coalesced, (
        f"expected {expected_coalesced} coalesced read requests, got {coalesced}"
    )

    logger.info("Broadcast read-coalescing e2e test passed")
