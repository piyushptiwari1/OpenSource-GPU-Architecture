import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger
from .test_warp_scheduling_e2e import DelayedMemory

# Scoreboarded-issue (posted memory op) end-to-end test.
#
# Plain LDR/STR are POSTED: the warp keeps executing while the access is in
# flight, and a one-entry scoreboard blocks only genuinely dependent
# instructions (RAW/WAW on the load destination, further memory ops, RET/BAR).
#
# The proof is an A/B comparison of two kernels with the SAME instructions
# (same loads, same stores, same result) in a different order, against the
# same slow memory:
#
#   Kernel A (software-pipelined): the load is issued EARLY, followed by four
#   independent ALU instructions; the dependent add comes last. The scoreboard
#   overlaps the memory latency with those instructions.
#
#   Kernel B (naive): the same independent instructions run BEFORE the load,
#   and the dependent add follows the load immediately - a RAW hazard with
#   nothing to hide behind, so the warp stalls for the full latency.
#
# Both kernels compute out[i] = in[i] + 33. Assertions:
#   1. Both kernels produce correct results (hazard interlocks are sound).
#   2. Both kernels post the same operations (2 per block: 1 LDR + 1 STR).
#   3. Kernel A finishes measurably faster than kernel B - instruction-level
#      latency hiding, on top of the existing warp-level hiding.

LATENCY = 8  # external data-memory latency per beat

KERNEL_A = [
    0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
    0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx     ; i
    0b0111000100000000,  # 2  LDR   R1, R0                 ; POSTED early
    0b1001001000001010,  # 3  CONST R2, #10                ; independent
    0b1001001100000011,  # 4  CONST R3, #3                 ; independent
    0b0101001000100011,  # 5  MUL   R2, R2, R3             ; independent (30)
    0b0011001000100011,  # 6  ADD   R2, R2, R3             ; independent (33)
    0b0011010000010010,  # 7  ADD   R4, R1, R2             ; RAW - lands late
    0b1001010100010000,  # 8  CONST R5, #16
    0b0011010101010000,  # 9  ADD   R5, R5, R0             ; &out[i]
    0b1000000001010100,  # 10 STR   R5, R4                 ; POSTED store
    0b1111000000000000,  # 11 RET                          ; drains the store
]

KERNEL_B = [
    0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
    0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx
    0b1001001000001010,  # 2  CONST R2, #10
    0b1001001100000011,  # 3  CONST R3, #3
    0b0101001000100011,  # 4  MUL   R2, R2, R3
    0b0011001000100011,  # 5  ADD   R2, R2, R3
    0b0111000100000000,  # 6  LDR   R1, R0                 ; POSTED...
    0b0011010000010010,  # 7  ADD   R4, R1, R2             ; ...RAW immediately
    0b1001010100010000,  # 8  CONST R5, #16
    0b0011010101010000,  # 9  ADD   R5, R5, R0
    0b1000000001010100,  # 10 STR   R5, R4
    0b1111000000000000,  # 11 RET
]

IN_DATA = [7, 3, 11, 2, 9, 5, 1, 6]

_results = {}


async def _run_kernel(dut, program, tag):
    # Deassert `start` from any previous kernel BEFORE the reset in setup():
    # with start still high through reset, the dispatcher restarts against
    # the cleared DCR (thread_count = 0 -> total_blocks = 0) and fires `done`
    # immediately, before the new program is even loaded. Plain deposit - no
    # clock is running yet on the first call.
    dut.start.value = 0

    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    data_memory = DelayedMemory(
        dut=dut, addr_bits=8, data_bits=8, channels=4, name="data", latency=LATENCY
    )
    data = IN_DATA + [0] * 24  # in[0..7], out region at 16..23

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
        assert cycles < 20000, f"kernel {tag} did not finish (drain deadlock?)"

    # Let the registered perf aggregations latch.
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # 1. Correctness: out[i] = in[i] + 33 (the posted load's deferred
    #    writeback and the RAW interlock both worked).
    for i in range(threads):
        expected = (IN_DATA[i] + 33) % 256
        result = data_memory.memory[16 + i]
        assert result == expected, (
            f"kernel {tag}: out[{i}] expected {expected}, got {result}"
        )

    posted = int(dut.perf_posted_count.value)
    logger.info(f"scoreboard kernel {tag}: cycles={cycles} posted_ops={posted}")

    # 2. Both kernels post 1 LDR + 1 STR per block, 2 blocks.
    assert posted == 4, f"kernel {tag}: expected 4 posted ops, got {posted}"

    _results[tag] = cycles
    return cycles


@cocotb.test()
async def test_scoreboard_overlapped(dut):
    """Kernel A: load issued early, latency hidden behind independent ALU work."""
    await _run_kernel(dut, KERNEL_A, "A")


@cocotb.test()
async def test_scoreboard_serial_baseline(dut):
    """Kernel B: dependent use immediately after the load - full RAW stall."""
    await _run_kernel(dut, KERNEL_B, "B")

    cycles_a = _results["A"]
    cycles_b = _results["B"]
    logger.info(
        f"scoreboard: overlapped={cycles_a} serial={cycles_b} "
        f"saved={cycles_b - cycles_a} cycles"
    )

    # 3. Same instructions, same memory traffic - the only difference is the
    #    schedule. The scoreboard must make the software-pipelined order
    #    measurably faster (the independent instructions execute inside the
    #    load's latency window instead of after it).
    assert cycles_a + 4 <= cycles_b, (
        f"expected the overlapped schedule ({cycles_a} cycles) to beat the "
        f"serial schedule ({cycles_b} cycles) - posted loads are not "
        f"overlapping execution with memory latency"
    )
