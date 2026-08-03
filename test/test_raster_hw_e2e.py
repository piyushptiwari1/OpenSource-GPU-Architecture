import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Fixed-function graphics hardware end-to-end test.
#
# Real GPUs pair programmable SIMT cores with fixed-function raster hardware.
# This test drives that exact split on the `gpu` top:
#
#   Phase 1 (fixed-function): the host submits primitives on the raster
#   command interface - a filled triangle and a rectangle - and the
#   rasterizer walks them in hardware, streaming covered pixels through the
#   raster writer into the framebuffer window of DATA MEMORY (base 64,
#   8-pixel row stride) via the shared memory controller + write-through L2.
#
#   Phase 2 (programmable): a SIMT kernel is launched that reads the
#   rendered framebuffer back with plain LDRs (one thread per row, summing
#   its row's pixels) and stores per-row sums - proving the two engines are
#   COHERENT through the shared memory hierarchy.
#
# Assertions:
#   1. The rendered framebuffer matches a software reference rasterizer that
#      replicates the RTL's edge-function convention pixel-for-pixel.
#   2. raster_busy covers the full path: when it deasserts, every pixel has
#      already been committed to (external) memory.
#   3. The kernel's row sums match the rendered image - the SIMT cores read
#      exactly what the fixed-function unit wrote.

OP_POINT = 0b001
OP_LINE = 0b010
OP_RECT = 0b011
OP_TRIANGLE = 0b100

FB_BASE = 64
FB_W = 8   # row stride (FB_WIDTH_LOG2 = 3)
FB_H = 8

TRI = ((0, 0), (0, 6), (6, 6))   # lower-left triangle, RTL winding (all e >= 0)
TRI_COLOR = 10
RECT = ((7, 0), (7, 7))          # rightmost column
RECT_COLOR = 3

# Read-back kernel: thread i sums framebuffer row i and stores it at 32 + i.
PROGRAM = [
    0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
    0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx     ; row
    0b1001000100001000,  # 2  CONST R1, #8                 ; width / loop bound
    0b0101001000000001,  # 3  MUL   R2, R0, R1
    0b1001001101000000,  # 4  CONST R3, #64
    0b0011001000100011,  # 5  ADD   R2, R2, R3             ; addr = 64 + row*8
    0b1001010000000000,  # 6  CONST R4, #0                 ; sum
    0b1001010100000000,  # 7  CONST R5, #0                 ; k
    0b1001011000000001,  # 8  CONST R6, #1
    0b0111011100100000,  # 9  LDR   R7, R2                 ; LOOP: load pixel
    0b0011010001000111,  # 10 ADD   R4, R4, R7             ; sum += pixel
    0b0011001000100110,  # 11 ADD   R2, R2, R6             ; addr++
    0b0011010101010110,  # 12 ADD   R5, R5, R6             ; k++
    0b0010000001010001,  # 13 CMP   R5, R1
    0b0001100000001001,  # 14 BRn   9                      ; while k < 8
    0b1001100000100000,  # 15 CONST R8, #32
    0b0011100010000000,  # 16 ADD   R8, R8, R0             ; &out[row]
    0b1000000010000100,  # 17 STR   R8, R4                 ; out[row] = sum
    0b1111000000000000,  # 18 RET
]


def edge_func(ax, ay, bx, by, px, py):
    """Exact replica of the RTL's edge function."""
    return (px - ax) * (by - ay) - (py - ay) * (bx - ax)


def reference_framebuffer():
    """Software rasterizer with the RTL's coverage convention."""
    fb = [[0] * FB_W for _ in range(FB_H)]
    (x0, y0), (x1, y1), (x2, y2) = TRI
    for y in range(min(y0, y1, y2), max(y0, y1, y2) + 1):
        for x in range(min(x0, x1, x2), max(x0, x1, x2) + 1):
            e0 = edge_func(x0, y0, x1, y1, x, y)
            e1 = edge_func(x1, y1, x2, y2, x, y)
            e2 = edge_func(x2, y2, x0, y0, x, y)
            if e0 >= 0 and e1 >= 0 and e2 >= 0:
                fb[y][x] = TRI_COLOR
    (rx0, ry0), (rx1, ry1) = RECT
    for y in range(min(ry0, ry1), max(ry0, ry1) + 1):
        for x in range(min(rx0, rx1), max(rx0, rx1) + 1):
            fb[y][x] = RECT_COLOR
    return fb


async def _submit(dut, data_memory, program_memory, op, v0, v1, v2, color):
    """Submit one primitive and run the memories until it fully commits."""
    dut.raster_cmd_op.value = op
    dut.raster_x0.value, dut.raster_y0.value = v0
    dut.raster_x1.value, dut.raster_y1.value = v1
    dut.raster_x2.value, dut.raster_y2.value = v2
    dut.raster_color.value = color
    dut.raster_cmd_valid.value = 1
    await RisingEdge(dut.clk)
    dut.raster_cmd_valid.value = 0

    # Serve memory handshakes until the walk finishes AND every pixel write
    # has been committed (raster_busy covers the raster writer too).
    for guard in range(5000):
        data_memory.run()
        program_memory.run()
        await cocotb.triggers.ReadOnly()
        busy = int(dut.raster_busy.value)
        ready = int(dut.raster_cmd_ready.value)
        await RisingEdge(dut.clk)
        if not busy and ready and guard > 2:
            return
    raise AssertionError("rasterizer did not finish the primitive")


@cocotb.test()
async def test_raster_hw_pipeline(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    data_memory = Memory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")

    # Manual bring-up (the shared setup() helper asserts start immediately;
    # here the fixed-function phase must run BEFORE the kernel launches).
    clock = Clock(dut.clk, 10, units="ns")
    cocotb.start_soon(clock.start())
    dut.start.value = 0
    dut.raster_cmd_valid.value = 0
    dut.reset.value = 1
    await RisingEdge(dut.clk)
    dut.reset.value = 0

    program_memory.load(PROGRAM)
    data_memory.load([0] * 128)

    dut.device_control_write_enable.value = 1
    dut.device_control_data.value = 8  # 8 threads: one per framebuffer row
    await RisingEdge(dut.clk)
    dut.device_control_write_enable.value = 0

    # ---- Phase 1: fixed-function rendering -------------------------------
    await _submit(dut, data_memory, program_memory,
                  OP_TRIANGLE, TRI[0], TRI[1], TRI[2], TRI_COLOR)
    await _submit(dut, data_memory, program_memory,
                  OP_RECT, RECT[0], RECT[1], (0, 0), RECT_COLOR)

    ref = reference_framebuffer()
    for y in range(FB_H):
        row = [data_memory.memory[FB_BASE + y * FB_W + x] for x in range(FB_W)]
        logger.info(f"fb row {y}: {row}")

    # 1+2. Hardware framebuffer matches the software reference, and it is
    # already visible in EXTERNAL memory (write-through L2) the moment
    # raster_busy deasserted.
    for y in range(FB_H):
        for x in range(FB_W):
            got = data_memory.memory[FB_BASE + y * FB_W + x]
            assert got == ref[y][x], (
                f"pixel ({x},{y}): hardware wrote {got}, reference says {ref[y][x]}"
            )

    # ---- Phase 2: SIMT read-back kernel -----------------------------------
    dut.start.value = 1

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()
        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)
        await RisingEdge(dut.clk)
        cycles += 1
        assert cycles < 20000, "read-back kernel did not finish"

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # 3. The programmable cores saw exactly what the fixed-function unit
    # rendered (coherence through the shared controller + L2).
    expected_sums = [sum(ref[y]) % 256 for y in range(FB_H)]
    for y in range(FB_H):
        got = data_memory.memory[32 + y]
        assert got == expected_sums[y], (
            f"row {y}: kernel summed {got}, rendered row sums to {expected_sums[y]}"
        )

    logger.info(
        f"raster hw pipeline: kernel_cycles={cycles} row_sums={expected_sums}"
    )
