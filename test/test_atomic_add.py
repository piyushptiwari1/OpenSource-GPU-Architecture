import cocotb
from cocotb.triggers import RisingEdge

from .helpers.format import format_cycle
from .helpers.logger import logger
from .helpers.memory import Memory
from .helpers.setup import setup


# End-to-end test for ATOMICADD (opcode 0xA, added in the cppref part-A
# commit and wired into the RTL decoder + LSU in part B).
#
# Eight threads each issue ATOMICADD R3, R1, R2 with R1 = 0x40 (counter
# address) and R2 = 1. After the kernel returns, mem[0x40] must equal 8
# regardless of warp scheduling, because the LSU's atomic FSM
# (REQ_R -> WAIT_R -> REQ_W -> WAIT_W -> DONE) prevents same-lane
# interleaving and the memory controller serialises the cross-warp
# requests via the existing ready/valid handshake.
@cocotb.test()
async def test_atomic_add_reduction(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    # Layout:
    #   CONST R1, 0x40     ; counter address (off the input data range)
    #   CONST R2, 1        ; increment
    #   ATOMICADD R3, R1, R2  ; old = mem[R1]; mem[R1] <- old+1; R3 <- old
    #   RET
    program = [
        0b1001_0001_01000000,  # CONST R1, #64
        0b1001_0010_00000001,  # CONST R2, #1
        0b1010_0011_00010010,  # ATOMICADD R3, R1, R2  (opcode 0xA)
        0b1111_0000_00000000,  # RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    # Pre-zero memory; the counter at 0x40 starts at 0.
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

        # Loose timeout — 8 threads each doing 4 instructions plus an
        # RMW round-trip should comfortably finish in a few hundred cycles.
        if cycles > 2000:
            raise AssertionError(f"timeout after {cycles} cycles")

    logger.info(f"Completed in {cycles} cycles")
    data_memory.display(72)

    counter = data_memory.memory[0x40]
    assert counter == threads, f"atomic counter wrong: expected {threads}, got {counter}"
