import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Nested branch-divergence stress test.
#
# This goes one level deeper than test_divergence_e2e: threads in the same
# block diverge, and then diverge AGAIN inside one of the taken paths, so the
# min-PC scheduler must stage multiple reconvergence points correctly. A naive
# (single shared PC) scheduler — or a reconvergence model that only handles a
# single level — would produce wrong results for at least one leaf.
#
# Control structure (decision is on the local %threadIdx, which is i % blockDim):
#
#   if (tid < 2):                 # outer "then"  (path A)
#       if (tid < 1):  result = i + 10     # tid == 0
#       else:          result = i + 20     # tid == 1
#   else:                         # outer "else"  (path B)
#       if (tid < 3):  result = i + 30     # tid == 2
#       else:          result = i + 40     # tid == 3
#   mem[i] = result               # reconverged store
#
# Kernel (PC : instruction):
#   0  MUL   R0, %blockIdx, %blockDim
#   1  ADD   R0, R0, %threadIdx            ; R0 = global thread index i
#   2  CONST R1, #2
#   3  CMP   %threadIdx, R1                ; N if tid < 2
#   4  BRn   14                            ; tid < 2 -> path A (PC 14)
#   ; ----- path B (tid >= 2) -----
#   5  CONST R1, #3
#   6  CMP   %threadIdx, R1                ; N if tid < 3  (=> tid == 2)
#   7  BRn   11                            ; tid == 2 -> leaf (PC 11)
#   8  CONST R2, #40                       ; tid == 3 leaf
#   9  ADD   R3, R0, R2
#   10 BRnzp 22                            ; -> reconverge
#   11 CONST R2, #30                       ; tid == 2 leaf
#   12 ADD   R3, R0, R2
#   13 BRnzp 22                            ; -> reconverge
#   ; ----- path A (tid < 2) -----
#   14 CONST R1, #1
#   15 CMP   %threadIdx, R1                ; N if tid < 1  (=> tid == 0)
#   16 BRn   20                            ; tid == 0 -> leaf (PC 20)
#   17 CONST R2, #20                       ; tid == 1 leaf
#   18 ADD   R3, R0, R2
#   19 BRnzp 22                            ; -> reconverge
#   20 CONST R2, #10                       ; tid == 0 leaf
#   21 ADD   R3, R0, R2
#   ; ----- reconverged -----
#   22 STR   R0, R3                        ; mem[i] = result
#   23 RET
@cocotb.test()
async def test_nested_divergence(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
        0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx
        0b1001000100000010,  # 2  CONST R1, #2
        0b0010000011110001,  # 3  CMP   %threadIdx, R1
        0b0001100000001110,  # 4  BRn   14
        0b1001000100000011,  # 5  CONST R1, #3
        0b0010000011110001,  # 6  CMP   %threadIdx, R1
        0b0001100000001011,  # 7  BRn   11
        0b1001001000101000,  # 8  CONST R2, #40
        0b0011001100000010,  # 9  ADD   R3, R0, R2
        0b0001111000010110,  # 10 BRnzp 22
        0b1001001000011110,  # 11 CONST R2, #30
        0b0011001100000010,  # 12 ADD   R3, R0, R2
        0b0001111000010110,  # 13 BRnzp 22
        0b1001000100000001,  # 14 CONST R1, #1
        0b0010000011110001,  # 15 CMP   %threadIdx, R1
        0b0001100000010100,  # 16 BRn   20
        0b1001001000010100,  # 17 CONST R2, #20
        0b0011001100000010,  # 18 ADD   R3, R0, R2
        0b0001111000010110,  # 19 BRnzp 22
        0b1001001000001010,  # 20 CONST R2, #10
        0b0011001100000010,  # 21 ADD   R3, R0, R2
        0b1000000000000011,  # 22 STR   R0, R3
        0b1111000000000000,  # 23 RET
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

    offsets = {0: 10, 1: 20, 2: 30, 3: 40}
    expected_results = [i + offsets[i % 4] for i in range(threads)]

    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i]
        assert result == expected, (
            f"Nested divergence mismatch at index {i}: expected {expected}, got {result}"
        )

    logger.info("Nested branch divergence test passed")
