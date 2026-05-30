import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Shared-memory (LDS/STS) + barrier end-to-end test.
#
# Every thread in the block publishes its value into per-block shared memory,
# synchronises on a BAR, then reads back a DIFFERENT lane's slot and stores the
# result to global memory. The cross-lane read (lane tid reads slot 3-tid) makes
# the test fail unless (a) shared memory genuinely carries data between lanes and
# (b) the barrier guarantees every STS has completed before any LDS runs.
#
#   value = i + 100                      # i = global thread index
#   shmem[tid] = value                   # STS publish
#   BAR                                  # all publishes are visible after here
#   mem[i] = shmem[3 - tid]              # LDS read a peer's slot, then store
#
# With a single block of blockDim = 4 the global index i == tid, so:
#   mem[i] = (3 - i) + 100 = 103 - i  ->  [103, 102, 101, 100]
#
# Kernel (PC : instruction):
#   0  MUL   R0, %blockIdx, %blockDim
#   1  ADD   R0, R0, %threadIdx          ; R0 = global index i
#   2  CONST R1, #100
#   3  ADD   R2, R0, R1                   ; R2 = i + 100  (value to publish)
#   4  STS   %threadIdx, R2               ; shmem[tid] = R2
#   5  BAR                                ; block-wide barrier
#   6  CONST R6, #3
#   7  SUB   R4, R6, %threadIdx           ; R4 = 3 - tid  (peer slot)
#   8  LDS   R5, R4                        ; R5 = shmem[3 - tid]
#   9  STR   R0, R5                        ; mem[i] = R5
#   10 RET
@cocotb.test()
async def test_shared_memory(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
        0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx
        0b1001000101100100,  # 2  CONST R1, #100
        0b0011001000000001,  # 3  ADD   R2, R0, R1
        0b1110000011110010,  # 4  STS   %threadIdx, R2
        0b1100000000000000,  # 5  BAR
        0b1001011000000011,  # 6  CONST R6, #3
        0b0100010001101111,  # 7  SUB   R4, R6, %threadIdx
        0b1101010101000000,  # 8  LDS   R5, R4
        0b1000000000000101,  # 9  STR   R0, R5
        0b1111000000000000,  # 10 RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [0, 0, 0, 0]

    threads = 4  # single block, blockDim = 4 -> shared memory is block-private

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    data_memory.display(4)

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        await RisingEdge(dut.clk)
        cycles += 1

    logger.info(f"Completed in {cycles} cycles")
    data_memory.display(4)

    expected_results = [103 - i for i in range(threads)]

    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i]
        assert result == expected, (
            f"Shared-memory result mismatch at index {i}: expected {expected}, got {result}"
        )

    logger.info("Shared memory (LDS/STS) + barrier e2e test passed")
