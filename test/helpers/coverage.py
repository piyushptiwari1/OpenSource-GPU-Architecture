"""Functional coverage helpers built on cocotb-coverage.

cocotb-coverage (https://github.com/mciepluc/cocotb-coverage, DVCon 2017) is the
de-facto market-standard functional / metric-driven-verification (MDV) coverage
extension for cocotb. Version 2.0 is the release adjusted for cocotb >= 2.0,
which matches the cocotb 2.0.x used by this project.

This module samples *functional* coverage of the SIMT core -- the FSM states it
visits and the ISA opcodes it actually executes -- and exports the coverage
database to the standard XML artifact consumed by MDV/coverage tooling.

It is observation-only: it reads DUT signals and never drives them, so it can
be layered onto any test without changing RTL behaviour.
"""

from pathlib import Path

from cocotb_coverage.coverage import CoverCross, CoverPoint, coverage_db

# --- Bin definitions -------------------------------------------------------

# All eight core FSM states (mirrors format_core_state in helpers/format.py).
CORE_STATES = [
    "IDLE",
    "FETCH",
    "DECODE",
    "REQUEST",
    "WAIT",
    "EXECUTE",
    "UPDATE",
    "DONE",
]

# ISA opcode mnemonics keyed by the top 4 instruction bits.
OPCODES = [
    "NOP",
    "BRnzp",
    "CMP",
    "ADD",
    "SUB",
    "MUL",
    "DIV",
    "LDR",
    "STR",
    "CONST",
    "BAR",
    "RET",
]

_STATE_MAP = {
    "000": "IDLE",
    "001": "FETCH",
    "010": "DECODE",
    "011": "REQUEST",
    "100": "WAIT",
    "101": "EXECUTE",
    "110": "UPDATE",
    "111": "DONE",
}

_OPCODE_MAP = {
    "0000": "NOP",
    "0001": "BRnzp",
    "0010": "CMP",
    "0011": "ADD",
    "0100": "SUB",
    "0101": "MUL",
    "0110": "DIV",
    "0111": "LDR",
    "1000": "STR",
    "1001": "CONST",
    "1100": "BAR",
    "1111": "RET",
}

# Opcode is only meaningful once the instruction has been fetched + decoded.
_OPCODE_VALID_STATES = frozenset({"DECODE", "REQUEST", "WAIT", "EXECUTE", "UPDATE"})


# --- Cover points ----------------------------------------------------------
# Each sampling function is decorated independently so that a coverpoint is only
# updated when its value is valid (e.g. opcode is not sampled while the core is
# IDLE/FETCH and the instruction register holds a stale/undefined value).


@CoverPoint("top.gpu.core_state", xf=lambda state: state, bins=CORE_STATES)
def _sample_state(state):
    pass


@CoverPoint("top.gpu.opcode", xf=lambda opcode: opcode, bins=OPCODES)
def _sample_opcode(opcode):
    pass


@CoverCross("top.gpu.state_x_opcode", items=["top.gpu.core_state", "top.gpu.opcode"])
def _sample_cross(state, opcode):
    pass


# --- Sampling --------------------------------------------------------------


def _decode_opcode(instruction_bits: str):
    if instruction_bits is None or len(instruction_bits) < 4:
        return None
    return _OPCODE_MAP.get(instruction_bits[0:4])


def sample_all(dut) -> None:
    """Sample functional coverage from every core in the GPU for this cycle.

    Call this once per simulated cycle (after a ReadOnly settle). Inactive cores
    sit in IDLE, which is a legitimate state bin, so sampling all cores is safe.
    """
    for core in dut.cores:
        inst = core.core_instance
        # The core is organised as warp slices; sample every warp's FSM and
        # the instruction it currently holds.
        for warp in inst.warps:
            state = _STATE_MAP.get(str(warp.core_state.value))
            if state is None:
                continue
            _sample_state(state)

            if state in _OPCODE_VALID_STATES:
                opcode = _decode_opcode(str(warp.instruction.value))
                if opcode is not None:
                    _sample_opcode(opcode)
                    _sample_cross(state, opcode)


# --- Reporting / export ----------------------------------------------------


def state_cover_percentage() -> float:
    return coverage_db["top.gpu.core_state"].cover_percentage


def opcode_cover_percentage() -> float:
    return coverage_db["top.gpu.opcode"].cover_percentage


def covered_opcodes() -> set:
    """Return the set of opcode mnemonics that were hit at least once."""
    detailed = coverage_db["top.gpu.opcode"].detailed_coverage
    return {name for name, hits in detailed.items() if hits > 0}


def export_xml(path: str = "test/coverage/functional_coverage.xml") -> str:
    """Export the coverage database to XML and return the absolute path."""
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    coverage_db.export_to_xml(filename=str(out))
    return str(out.resolve())
