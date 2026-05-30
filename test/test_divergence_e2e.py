import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# End-to-end branch-divergence test.
#
# This exercises the min-PC SIMT reconvergence implemented in scheduler.sv /
# core.sv. Threads in the SAME block take DIFFERENT control-flow paths based on
# their (local) %threadIdx, then reconverge before storing their result:
#
#   - local threadIdx <  2  -> "path A":  result = global_i + 100
#   - local threadIdx >= 2  -> "path B":  result = global_i + 200
#
# If divergence is handled correctly, both paths execute and every thread
# stores the value dictated by the path it actually took. A scheduler that
# collapsed all lanes onto a single PC (the old behaviour) would compute the
# wrong value for at least one of the two groups.
#
# Kernel (PC : instruction):
#   0  MUL   R0, %blockIdx, %blockDim      ; R0 = blockIdx * blockDim
#   1  ADD   R0, R0, %threadIdx            ; R0 = global thread index i
#   2  CONST R1, #2                        ; branch threshold (local tid)
#   3  CMP   %threadIdx, R1                ; sets N if threadIdx < 2
#   4  BRn   8                             ; threadIdx < 2 -> path A (PC 8)
#   ; ---- path B (threadIdx >= 2) ----
#   5  CONST R2, #200
#   6  ADD   R3, R0, R2                    ; result = i + 200
#   7  BRnzp 10                            ; unconditional -> reconverge (PC 10)
#   ; ---- path A (threadIdx < 2) ----
#   8  CONST R2, #100
#   9  ADD   R3, R0, R2                    ; result = i + 100
#   ; ---- reconverged ----
#   10 STR   R0, R3                        ; mem[i] = result
#   11 RET
@cocotb.test()
async def test_divergence_e2e(dut):
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
        0b1000000000000011,  # 10 STR   R0, R3
        0b1111000000000000,  # 11 RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    # No input data is required; the kernel writes results into mem[0..7].
    data = [0, 0, 0, 0, 0, 0, 0, 0]

    threads = 8

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

    # global i = blockIdx*blockDim + threadIdx; with blockDim = 4 the local
    # threadIdx is i % 4, which decides the branch each thread takes.
    expected_results = []
    for i in range(threads):
        local_tid = i % 4
        expected_results.append(i + (100 if local_tid < 2 else 200))

    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i]
        assert result == expected, (
            f"Divergence mismatch at index {i}: expected {expected}, got {result}"
        )

    logger.info("Branch divergence e2e test passed")
