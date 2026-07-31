import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Graphics (software rasterizer) end-to-end test.
#
# Demonstrates the graphics workload the README roadmap asks for, expressed as
# a pure SIMT kernel on the existing ISA - exactly how early GPGPU rasterizers
# worked. One thread is launched per pixel of a 4x4 framebuffer; each thread:
#
#   1. derives its pixel coordinates (x = i % 4, y = i / 4) from its global
#      thread index,
#   2. evaluates the edge function of the triangle (0,0)-(0,3)-(3,3) as the
#      half-plane test x <= y (the two other edges bound the framebuffer),
#   3. branches on the coverage result (real per-pixel divergence!), and
#   4. writes the shaded color into the framebuffer region of data memory
#      (inside = 200, outside = 50).
#
# The test verifies the rendered image pixel-for-pixel against a software
# reference rasterizer and asserts the branch really diverged inside warps.
#
# Kernel (PC : instruction):
#   0  MUL   R0, %blockIdx, %blockDim
#   1  ADD   R0, R0, %threadIdx          ; i = pixel index (0..15)
#   2  CONST R1, #4                      ; framebuffer width
#   3  DIV   R2, R0, R1                  ; y = i / 4
#   4  MUL   R3, R2, R1
#   5  SUB   R3, R0, R3                  ; x = i % 4
#   6  CONST R4, #16                     ; framebuffer base address
#   7  ADD   R4, R4, R0                  ; &fb[i]
#   8  CMP   R3, R2                      ; edge function: sign(x - y)
#   9  BRp   13                          ; x > y -> outside the triangle
#   10 CONST R5, #200                    ; inside color
#   11 STR   R4, R5                      ; fb[i] = 200
#   12 BRnzp 15                          ; skip the outside path
#   13 CONST R5, #50                     ; outside color
#   14 STR   R4, R5                      ; fb[i] = 50
#   15 RET
@cocotb.test()
async def test_graphics_e2e(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
        0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx
        0b1001000100000100,  # 2  CONST R1, #4
        0b0110001000000001,  # 3  DIV   R2, R0, R1
        0b0101001100100001,  # 4  MUL   R3, R2, R1
        0b0100001100000011,  # 5  SUB   R3, R0, R3
        0b1001010000010000,  # 6  CONST R4, #16
        0b0011010001000000,  # 7  ADD   R4, R4, R0
        0b0010000000110010,  # 8  CMP   R3, R2
        0b0001001000001101,  # 9  BRp   13
        0b1001010111001000,  # 10 CONST R5, #200
        0b1000000001000101,  # 11 STR   R4, R5
        0b0001111000001111,  # 12 BRnzp 15
        0b1001010100110010,  # 13 CONST R5, #50
        0b1000000001000101,  # 14 STR   R4, R5
        0b1111000000000000,  # 15 RET
    ]

    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    # 0..15 reserved (would hold vertex/uniform data in a fuller pipeline);
    # 16..31 is the 4x4 framebuffer, initially zero.
    data = [0] * 32

    width = 4
    threads = 16  # one thread per pixel -> 4 blocks of blockDim = 4

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

    # Let the registered top-level perf aggregation latch the final counts.
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # Software reference rasterizer: pixel (x, y) is covered iff x <= y.
    INSIDE, OUTSIDE = 200, 50
    expected = [
        INSIDE if x <= y else OUTSIDE
        for y in range(width)
        for x in range(width)
    ]

    frame = [data_memory.memory[16 + i] for i in range(width * width)]
    for y in range(width):
        row = frame[y * width:(y + 1) * width]
        logger.info(f"fb row {y}: {row}")

    for i, (got, want) in enumerate(zip(frame, expected)):
        x, y = i % width, i // width
        assert got == want, (
            f"pixel ({x},{y}): expected {want}, got {got}"
        )

    # The coverage branch must have really diverged inside at least one warp
    # (e.g. row 0 splits lanes into 1 inside / 3 outside).
    perf_diverge = int(dut.perf_divergence_count.value)
    logger.info(f"graphics: cycles={cycles} divergence_steps={perf_diverge}")
    assert perf_diverge > 0, (
        "per-pixel coverage branch should diverge within a warp"
    )
