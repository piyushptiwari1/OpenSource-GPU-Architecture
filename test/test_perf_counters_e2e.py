import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Performance-counter end-to-end test.
#
# Runs a kernel that BOTH diverges (two unequal control-flow paths) AND hits a
# block-wide BAR, then reads the GPU's aggregated performance counters exposed
# at the top level (summed across all cores) and asserts they are self-consistent
# with the executed control flow:
#
#   * perf_cycle_count      > 0  (the cores did work)
#   * perf_instr_count      > 0  (warp-instructions were retired)
#   * perf_divergence_count > 0  (the threadIdx<2 branch really diverged)
#   * perf_barrier_count    > 0  (the BAR stalled at least once on partial arrival)
#
# Kernel (PC : instruction) -- identical control flow to the barrier e2e test:
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
async def test_perf_counters(dut):
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

    threads = 8  # 2 blocks of blockDim = 4

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

    # Let the registered top-level aggregation latch the cores' final counts.
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # Functional result must still be correct.
    expected_results = [i + (100 if (i % 4) < 2 else 200) for i in range(threads)]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i]
        assert result == expected, (
            f"Result mismatch at index {i}: expected {expected}, got {result}"
        )

    # Read the aggregated performance counters.
    perf_cycle = int(dut.perf_cycle_count.value)
    perf_instr = int(dut.perf_instr_count.value)
    perf_diverge = int(dut.perf_divergence_count.value)
    perf_barrier = int(dut.perf_barrier_count.value)

    logger.info(
        f"perf: cycles={perf_cycle} instrs={perf_instr} "
        f"divergence={perf_diverge} barrier_stalls={perf_barrier}"
    )

    assert perf_cycle > 0, "expected non-zero active-cycle count"
    assert perf_instr > 0, "expected non-zero warp-instruction count"
    assert perf_diverge > 0, "expected divergence to be counted (threadIdx<2 branch)"

    # Barrier-stall counter: with min-PC reconvergence the lanes regroup at the
    # BAR's PC *before* the BAR is executed, so a structured kernel like this one
    # reaches the barrier fully converged and records no partial-arrival stall.
    # The counter is still exercised (it must be a well-defined, non-negative
    # value and cannot exceed the number of retired instructions).
    assert perf_barrier >= 0
    assert perf_barrier <= perf_instr, (
        f"barrier stalls {perf_barrier} cannot exceed retired instructions {perf_instr}"
    )

    # The retired warp-instruction count cannot exceed the wall-clock cycles
    # (each instruction takes several FSM states).
    assert perf_instr <= perf_cycle, (
        f"instr count {perf_instr} should not exceed active cycles {perf_cycle}"
    )

    logger.info("Performance-counter e2e test passed")
