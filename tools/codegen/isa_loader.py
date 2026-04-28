"""Typed loader / validator for ``docs/isa/instructions.yaml``.

Why a dedicated module
----------------------
* The YAML is the single source of truth for the assembler, the C++ ref
  simulator, the docs site, and (eventually) DiffTest. Validating it once
  here keeps the templates dumb (no defensive logic in Jinja).
* Validation surfaces drift from RTL early: e.g. if someone adds a new
  control signal in ``decoder.sv`` they must declare it here, otherwise
  codegen fails loudly.

The loader has no third-party deps beyond ``PyYAML`` (already pinned via
the toolchain image).
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

# Mirrors src/decoder.sv state encoding so the C++ refsim can compare against
# the live RTL output bus during DiffTest.
DECODER_DECODE_STATE: int = 0b010
DECODER_EXECUTE_STATE: int = 0b101


class IsaError(ValueError):
    """Raised when the ISA YAML is structurally invalid."""


@dataclass(frozen=True)
class Register:
    id: int
    name: str
    alias: str | None = None
    readonly: bool = False


@dataclass(frozen=True)
class ControlSignal:
    name: str
    width: int


@dataclass(frozen=True)
class Instruction:
    mnemonic: str
    opcode: int
    type: str  # R, I, B, Z
    syntax: str
    semantics: str
    control: dict[str, int]


@dataclass(frozen=True)
class Isa:
    name: str
    word_bits: int
    data_bits: int
    addr_bits: int
    num_registers: int
    nzp_bits: int
    registers: tuple[Register, ...]
    control_signals: tuple[ControlSignal, ...]
    instructions: tuple[Instruction, ...]
    version: int = 1

    # ----- helpers used by the templates -------------------------------------

    def control_signal_names(self) -> list[str]:
        return [c.name for c in self.control_signals]

    def instruction_by_opcode(self) -> dict[int, Instruction]:
        return {i.opcode: i for i in self.instructions}


# ---------------------------------------------------------------------------
# Loading + validation
# ---------------------------------------------------------------------------

_VALID_TYPES = {"R", "I", "B", "Z"}


def _require(condition: bool, msg: str) -> None:
    if not condition:
        raise IsaError(msg)


def load(path: str | Path) -> Isa:
    """Load and validate the ISA YAML."""
    raw = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    _require(isinstance(raw, dict), "top-level must be a mapping")

    version = int(raw.get("version", 1))
    _require(version == 1, f"unsupported ISA spec version {version}")

    isa_block = raw.get("isa")
    _require(isinstance(isa_block, dict), "missing top-level 'isa:' mapping")
    instructions_block = raw.get("instructions")
    _require(
        isinstance(instructions_block, list) and instructions_block,
        "'instructions:' must be a non-empty list",
    )

    registers = tuple(_load_registers(isa_block.get("registers", [])))
    control_signals = tuple(_load_control_signals(isa_block.get("control_signals", [])))

    cs_names = {c.name for c in control_signals}
    instructions = tuple(_load_instructions(instructions_block, cs_names))

    # Cross-checks
    _check_unique([i.mnemonic for i in instructions], "mnemonic")
    _check_unique([i.opcode for i in instructions], "opcode")
    for ins in instructions:
        for sig in cs_names:
            _require(
                sig in ins.control,
                f"instruction {ins.mnemonic} missing control signal {sig!r}",
            )
        for sig, val in ins.control.items():
            _require(
                sig in cs_names,
                f"instruction {ins.mnemonic} declares unknown control signal {sig!r}",
            )
            cs = next(c for c in control_signals if c.name == sig)
            _require(
                0 <= val < (1 << cs.width),
                f"{ins.mnemonic}.{sig}={val} does not fit in {cs.width} bits",
            )

    return Isa(
        name=str(isa_block.get("name", "opengpu")),
        word_bits=int(isa_block.get("word_bits", 16)),
        data_bits=int(isa_block.get("data_bits", 8)),
        addr_bits=int(isa_block.get("addr_bits", 8)),
        num_registers=int(isa_block.get("num_registers", 16)),
        nzp_bits=int(isa_block.get("nzp_bits", 3)),
        registers=registers,
        control_signals=control_signals,
        instructions=instructions,
        version=version,
    )


def _load_registers(raw: list[Any]) -> list[Register]:
    out: list[Register] = []
    for item in raw:
        _require(isinstance(item, dict), f"register entry must be mapping: {item!r}")
        out.append(
            Register(
                id=int(item["id"]),
                name=str(item["name"]),
                alias=str(item["alias"]) if item.get("alias") else None,
                readonly=bool(item.get("readonly", False)),
            )
        )
    _check_unique([r.id for r in out], "register id")
    _check_unique([r.name for r in out], "register name")
    return out


def _load_control_signals(raw: list[Any]) -> list[ControlSignal]:
    out: list[ControlSignal] = []
    for item in raw:
        _require(isinstance(item, dict), f"control signal must be mapping: {item!r}")
        cs = ControlSignal(name=str(item["name"]), width=int(item["width"]))
        _require(cs.width >= 1, f"control signal {cs.name} has non-positive width")
        out.append(cs)
    _check_unique([c.name for c in out], "control signal name")
    return out


_OPCODE_MAX = 0xF  # 4-bit opcode field in instr[15:12]


def _load_instructions(raw: list[Any], cs_names: set[str]) -> list[Instruction]:
    out: list[Instruction] = []
    for item in raw:
        _require(isinstance(item, dict), f"instruction must be mapping: {item!r}")
        opcode = _parse_int(item["opcode"])
        _require(0 <= opcode <= _OPCODE_MAX, f"opcode {opcode!r} out of 4-bit range")
        ty = str(item["type"]).strip()
        _require(ty in _VALID_TYPES, f"unknown instruction type {ty!r}")
        control_raw = item.get("control") or {}
        _require(
            isinstance(control_raw, dict),
            f"instruction {item.get('mnemonic')} 'control' must be mapping",
        )
        out.append(
            Instruction(
                mnemonic=str(item["mnemonic"]),
                opcode=opcode,
                type=ty,
                syntax=str(item.get("syntax", "")),
                semantics=str(item.get("semantics", "")),
                control={str(k): int(v) for k, v in control_raw.items()},
            )
        )
    return out


def _parse_int(v: Any) -> int:
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        return int(v, 0)
    raise IsaError(f"cannot parse integer {v!r}")


def _check_unique(items: list[Any], label: str) -> None:
    seen: set[Any] = set()
    for x in items:
        if x in seen:
            raise IsaError(f"duplicate {label}: {x!r}")
        seen.add(x)
