import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# This test verifies that the "vector add" kernel runs correctly. The flow is:
#   1. Pre-load program memory and data memory.
#   2. Start the GPU simulation.
#   3. Drive the software memory model and log internal state every cycle.
#   4. Wait for `dut.done` to go high.
#   5. Compare the final data memory contents against the expected results.
@cocotb.test()
# `@cocotb.test()` is a decorator that tells cocotb the following coroutine is
# a test entry point.
async def test_matadd(dut):
    # Program Memory -- this is the *Python* program memory model used by the
    # testbench, not a real SRAM in the RTL.
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    # Each entry in `program` is a 16-bit instruction whose layout matches
    # `decoder.sv`.
    program = [
        0b0101000011011110, # MUL R0, %blockIdx, %blockDim
        0b0011000000001111, # ADD R0, R0, %threadIdx         ; i = blockIdx * blockDim + threadIdx
        0b1001000100000000, # CONST R1, #0                   ; baseA (matrix A base address)
        0b1001001000001000, # CONST R2, #8                   ; baseB (matrix B base address)
        0b1001001100010000, # CONST R3, #16                  ; baseC (matrix C base address)
        0b0011010000010000, # ADD R4, R1, R0                 ; addr(A[i]) = baseA + i
        0b0111010001000000, # LDR R4, R4                     ; load A[i] from global memory
        0b0011010100100000, # ADD R5, R2, R0                 ; addr(B[i]) = baseB + i
        0b0111010101010000, # LDR R5, R5                     ; load B[i] from global memory
        0b0011011001000101, # ADD R6, R4, R5                 ; C[i] = A[i] + B[i]
        0b0011011100110000, # ADD R7, R3, R0                 ; addr(C[i]) = baseC + i
        0b1000000001110110, # STR R7, R6                     ; store C[i] in global memory
        0b1111000000000000, # RET                            ; end of kernel
    ]

    # Data Memory -- 8 bits wide with 4 parallel access channels, matching the
    # GPU top-level parameters.
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    data = [
        0, 1, 2, 3, 4, 5, 6, 7, # Matrix A (1 x 8)
        0, 1, 2, 3, 4, 5, 6, 7  # Matrix B (1 x 8)
    ]

    # Device Control -- vector add launches 8 threads, one per element.
    threads = 8

    # `setup()` handles clock, reset, memory pre-loading, DCR programming and
    # raising `start` in one call.
    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads
    )

    # Print the initial memory contents so the log can be diffed against the
    # final state.
    data_memory.display(24)

    cycles = 0
    # `dut.done` is the GPU top-level output asserted when the kernel has
    # finished executing.
    while dut.done.value != 1:
        # Each cycle, advance the Python data/program memory models so they
        # respond to whatever read/write requests the RTL is issuing.
        data_memory.run()
        program_memory.run()

        # `ReadOnly()` waits until all RTL updates for the current simulation
        # time have settled, so the log captures stable signal values.
        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        # Finally wait for the rising edge of clk to advance to the next cycle.
        await RisingEdge(dut.clk)
        cycles += 1

    logger.info(f"Completed in {cycles} cycles")
    data_memory.display(24)

    expected_results = [a + b for a, b in zip(data[0:8], data[8:16])]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i + 16]
        assert result == expected, f"Result mismatch at index {i}: expected {expected}, got {result}"