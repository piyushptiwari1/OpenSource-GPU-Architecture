import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Barrier (BAR) end-to-end test.
#
# Threads in the same block diverge onto two different-length compute paths,
# then hit a block-wide BAR before the final store. The barrier requires every
# live lane to arrive before any lane proceeds past it; the scheduler holds
# arriving lanes until the whole block has reached the BAR, then releases them
# together. This test confirms BAR integrates correctly (no deadlock, no
# corruption) on top of min-PC divergence and that results are correct.
#
#   if (tid < 2):  result = i + 100      # path A
#   else:          result = i + 200      # path B
#   BAR                                  # all threads synchronise here
#   mem[i] = result
#
# Kernel (PC : instruction):
#   0  MUL   R0, %blockIdx, %blockDim
#   1  ADD   R0, R0, %threadIdx            ; R0 = global thread index i
#   2  CONST R1, #2
#   3  CMP   %threadIdx, R1                ; N if tid < 2
#   4  BRn   8                             ; tid < 2 -> path A (PC 8)
#   5  CONST R2, #200                      ; path B
#   6  ADD   R3, R0, R2
#   7  BRnzp 10
#   8  CONST R2, #100                      ; path A
#   9  ADD   R3, R0, R2
#   10 BAR                                 ; block-wide barrier
#   11 STR   R0, R3
#   12 RET
@cocotb.test()
async def test_barrier(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
        0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx
        0b1001000100000010,  # 2  CONST R1, #2
        0b0010000011110001,  # 3  CMP   %threadIdx, R1
        0b0001100000001000,  # 4  BRn   8
        0b1001001011001000,  # 5  CONST R2, #200
        0b0011001100000010,  # 6  ADD   R3, R0, R2
        0b0001111000001010,  # 7  BRnzp 10
        0b1001001001100100,  # 8  CONST R2, #100
        0b0011001100000010,  # 9  ADD   R3, R0, R2
        0b1100000000000000,  # 10 BAR
        0b1000000000000011,  # 11 STR   R0, R3
        0b1111000000000000,  # 12 RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0, 0, 0, 0, 0, 0, 0, 0]

    threads = 8  # 2 blocks of blockDim = 4, so local tid = i % 4

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    data_memory.display(8)

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        await RisingEdge(dut.clk)
        cycles += 1

    logger.info(f"Completed in {cycles} cycles")
    data_memory.display(8)

    expected_results = [i + (100 if (i % 4) < 2 else 200) for i in range(threads)]

    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i]
        assert result == expected, (
            f"Barrier result mismatch at index {i}: expected {expected}, got {result}"
        )

    logger.info("Barrier (BAR) e2e test passed")
