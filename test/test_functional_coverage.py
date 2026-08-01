"""End-to-end functional-coverage test.

Runs a divergent + barrier kernel (the same control flow as the perf-counter
e2e test, which retires MUL/ADD/CONST/CMP/BRnzp/BAR/STR/RET and exercises a
memory access) while sampling SIMT functional coverage every cycle using
cocotb-coverage -- the market-standard functional/MDV coverage library for
cocotb.

The test then:
  * exports the coverage database to test/coverage/functional_coverage.xml, and
  * asserts coverage closure on the core FSM (all 8 states reached) and that
    every opcode the kernel issues was sampled.

It is observation-only -- no RTL behaviour changes -- and additionally checks
the functional result so it doubles as a correctness regression.
"""

import cocotb
from cocotb.triggers import RisingEdge

from .helpers import coverage
from .helpers.logger import logger
from .helpers.memory import Memory
from .helpers.setup import setup

# Opcodes this kernel is expected to issue.
_EXPECTED_OPCODES = {"MUL", "ADD", "CONST", "CMP", "BRnzp", "BAR", "STR", "RET", "ATOMICADD"}


@cocotb.test()
async def test_functional_coverage(dut):
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
        # ATOMICADD keeps the synchronous WAIT path alive in coverage: plain
        # LDR/STR are POSTED by the scoreboard and skip WAIT entirely, so an
        # atomic (which must hold its controller address lock through the
        # read-modify-write) is now the canonical way to reach that state.
        0b1001010100000001,  # 11 CONST R5, #1
        0b1001101000011110,  # 12 CONST R10, #30
        0b1010100110100101,  # 13 ATOMICADD R9, R10, R5   ; mem[30] += 1
        0b1000000000000011,  # 14 STR   R0, R3
        0b1111000000000000,  # 15 RET
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
        coverage.sample_all(dut)

        await RisingEdge(dut.clk)
        cycles += 1

    # Functional correctness must still hold.
    expected_results = [i + (100 if (i % 4) < 2 else 200) for i in range(threads)]
    for i, expected in enumerate(expected_results):
        result = data_memory.memory[i]
        assert result == expected, (
            f"Result mismatch at index {i}: expected {expected}, got {result}"
        )

    # The atomic counter saw one increment per thread (also proves the
    # WAIT-path atomics still serialise correctly under the scoreboard).
    assert data_memory.memory[30] == threads, (
        f"atomic counter: expected {threads}, got {data_memory.memory[30]}"
    )

    # Export the coverage database (standard MDV XML artifact).
    xml_path = coverage.export_xml()
    state_pct = coverage.state_cover_percentage()
    opcode_pct = coverage.opcode_cover_percentage()
    seen_opcodes = coverage.covered_opcodes()

    logger.info(
        f"functional coverage: core_state={state_pct:.1f}% "
        f"opcode={opcode_pct:.1f}% opcodes_seen={sorted(seen_opcodes)}"
    )
    logger.info(f"coverage XML written to {xml_path}")

    # Coverage closure: every FSM state must have been visited.
    assert state_pct == 100.0, (
        f"core FSM coverage not closed: {state_pct:.1f}% "
        f"(all 8 states must be reached)"
    )

    # Every opcode the kernel issues must have been sampled.
    missing = _EXPECTED_OPCODES - seen_opcodes
    assert not missing, f"expected opcodes not covered: {sorted(missing)}"

    logger.info("Functional-coverage e2e test passed")
