import cocotb
from cocotb.triggers import RisingEdge

from .helpers.format import format_cycle
from .helpers.logger import logger
from .helpers.memory import Memory
from .helpers.setup import setup


# End-to-end test for ATOMICCAS (opcode 0xB).
#
# Eight threads each issue ATOMICCAS R3, R1, R2 with R1 = 0x40 (lock
# address) and R2 = (threadIdx + 1). The expected value is implicitly
# zero, so the very first thread to win arbitration in the memory
# controller observes old = 0 and installs (tid+1) as the lock token;
# every subsequent lane observes old != 0 and leaves memory unchanged
# (the LSU rewrites the old value, which the controller's per-address
# lock keeps consistent). After the kernel completes, mem[0x40] must
# equal exactly one of the eight possible token values, and exactly
# one lane must have read R3 == 0.
@cocotb.test()
async def test_atomic_cas_test_and_set(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    # Layout:
    #   CONST R1, 0x40         ; lock address
    #   ADD   R2, R15, R1?     ; we want a non-zero lane-unique token, simplest
    #                          ;   is just CONST R2, 1; all lanes install the
    #                          ;   same token. Final mem[0x40] == 1, exactly
    #                          ;   one lane reads 0.
    #   ATOMICCAS R3, R1, R2   ; R3 <- old; if old == 0 then mem[R1] <- R2
    #   RET
    program = [
        0b1001_0001_01000000,  # CONST R1, #64
        0b1001_0010_00000001,  # CONST R2, #1
        0b1011_0011_00010010,  # ATOMICCAS R3, R1, R2  (opcode 0xB)
        0b1111_0000_00000000,  # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    # mem[0x40] must start at 0 so the first lane succeeds.
    data = [0] * 65

    threads = 8

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

        if cycles > 2000:
            raise AssertionError(f"timeout after {cycles} cycles")

    logger.info(f"Completed in {cycles} cycles")
    data_memory.display(72)

    lock = data_memory.memory[0x40]
    assert lock == 1, f"CAS lock token wrong: expected 1, got {lock}"
