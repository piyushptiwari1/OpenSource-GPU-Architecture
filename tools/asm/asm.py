"""Minimal Python assembler for the OpenGPU 16-bit ISA.

Reads the canonical ISA spec from ``docs/isa/instructions.yaml`` and emits a
hex file (one 16-bit word per line, big-endian, lower-case) consumable by
``opengpu-refsim --program`` and ``$readmemh`` in the FPGA wrapper.

This is the in-house alternative to ``customasm``: zero external runtime
deps beyond ``pyyaml``, drives the same single-source-of-truth YAML.

Supported syntax
----------------
- Labels:        ``label:``
- R-type:        ``ADD R0, R1, R2``
- I-type:        ``CONST R3, #42`` or ``CONST R3, 0x2A``
- Z-type:        ``NOP`` / ``RET``
- B-type:        ``BRnzp <nzp3>, <label-or-imm>`` where nzp3 is a 3-bit
                 mask (e.g. ``0b110`` for "n or z") or a mnemonic mask
                 like ``nz``, ``p``, ``nzp``.
- Register aliases: ``%blockIdx``, ``%blockDim``, ``%threadIdx``.
- Comments: ``;`` to end of line.

Example
-------
    CONST R0, #0          ; addr 0
    CONST R1, #42
    STR   R0, R1          ; mem[0] = 42
    RET
"""

from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
ISA_YAML = REPO_ROOT / "docs" / "isa" / "instructions.yaml"

REG_ALIASES = {
    "%blockidx": 13,
    "%blockdim": 14,
    "%threadidx": 15,
}

NZP_MNEMONIC = {
    "n": 0b100,
    "z": 0b010,
    "p": 0b001,
    "nz": 0b110,
    "np": 0b101,
    "zp": 0b011,
    "nzp": 0b111,
}


class AsmError(RuntimeError):
    """Assembler error with line context."""


@dataclass(frozen=True)
class Op:
    mnemonic: str
    opcode: int
    type: str  # R, I, B, Z


def load_isa(path: Path = ISA_YAML) -> dict[str, Op]:
    raw = yaml.safe_load(path.read_text())
    table: dict[str, Op] = {}
    for entry in raw["instructions"]:
        op = Op(entry["mnemonic"], int(entry["opcode"]), entry["type"])
        table[op.mnemonic.lower()] = op
    return table


def _strip_comment(line: str) -> str:
    # Only ``;`` is a comment marker. ``#`` is reserved for immediate prefix
    # (``CONST R0, #42``); using it for comments would conflict.
    i = line.find(";")
    if i >= 0:
        line = line[:i]
    return line.strip()


def _parse_reg(tok: str, lineno: int) -> int:
    t = tok.strip().lower()
    if t in REG_ALIASES:
        return REG_ALIASES[t]
    if not t.startswith("r"):
        raise AsmError(f"line {lineno}: expected register, got '{tok}'")
    try:
        n = int(t[1:])
    except ValueError as e:
        raise AsmError(f"line {lineno}: bad register '{tok}'") from e
    if not 0 <= n <= 15:
        raise AsmError(f"line {lineno}: register out of range '{tok}'")
    return n


def _parse_imm(tok: str, bits: int, lineno: int, *, labels: dict[str, int] | None = None) -> int:
    t = tok.strip().lstrip("#")
    if labels is not None and t in labels:
        v = labels[t]
    elif t.lower() in NZP_MNEMONIC:
        v = NZP_MNEMONIC[t.lower()]
    elif t.lower().startswith("0b"):
        v = int(t, 2)
    else:
        v = int(t, 0)
    if not 0 <= v < (1 << bits):
        raise AsmError(f"line {lineno}: immediate '{tok}' = {v} out of {bits}-bit range")
    return v


def _split_operands(rest: str) -> list[str]:
    return [t for t in re.split(r"[ ,\t]+", rest.strip()) if t]


def assemble(source: str, isa: dict[str, Op] | None = None) -> list[int]:
    """Assemble *source* text into a list of 16-bit words.

    Two-pass: first collects labels (each instruction = 1 word), then encodes.
    """
    isa = isa or load_isa()

    # Pass 1: strip, collect labels, keep (lineno, mnemonic, operands_str)
    cleaned: list[tuple[int, str, str]] = []
    labels: dict[str, int] = {}
    pc = 0
    for raw_lineno, raw in enumerate(source.splitlines(), start=1):
        line = _strip_comment(raw)
        if not line:
            continue
        # Allow "label: INSTR ..." on one line.
        m = re.match(r"^([A-Za-z_][\w]*):\s*(.*)$", line)
        if m:
            label, rest = m.group(1), m.group(2)
            if label in labels:
                raise AsmError(f"line {raw_lineno}: duplicate label '{label}'")
            labels[label] = pc
            line = rest.strip()
            if not line:
                continue
        parts = line.split(None, 1)
        mnemonic = parts[0]
        operands = parts[1] if len(parts) > 1 else ""
        cleaned.append((raw_lineno, mnemonic, operands))
        pc += 1

    # Pass 2: encode.
    words: list[int] = []
    for lineno, mnemonic, operands in cleaned:
        key = mnemonic.lower()
        if key not in isa:
            raise AsmError(f"line {lineno}: unknown mnemonic '{mnemonic}'")
        op = isa[key]
        toks = _split_operands(operands)
        opcode = op.opcode & 0xF
        if op.type == "Z":
            if toks:
                raise AsmError(f"line {lineno}: {mnemonic} takes no operands")
            word = opcode << 12
        elif op.type == "R":
            if op.mnemonic in ("CMP", "STR"):
                if len(toks) != 2:
                    raise AsmError(f"line {lineno}: {mnemonic} expects 2 operands")
                rs = _parse_reg(toks[0], lineno)
                rt = _parse_reg(toks[1], lineno)
                word = (opcode << 12) | (0 << 8) | (rs << 4) | rt
            elif op.mnemonic == "LDR":
                if len(toks) != 2:
                    raise AsmError(f"line {lineno}: LDR expects 2 operands")
                rd = _parse_reg(toks[0], lineno)
                rs = _parse_reg(toks[1], lineno)
                word = (opcode << 12) | (rd << 8) | (rs << 4) | 0
            else:
                if len(toks) != 3:
                    raise AsmError(f"line {lineno}: {mnemonic} expects 3 operands")
                rd = _parse_reg(toks[0], lineno)
                rs = _parse_reg(toks[1], lineno)
                rt = _parse_reg(toks[2], lineno)
                word = (opcode << 12) | (rd << 8) | (rs << 4) | rt
        elif op.type == "I":
            if len(toks) != 2:
                raise AsmError(f"line {lineno}: {mnemonic} expects 2 operands")
            rd = _parse_reg(toks[0], lineno)
            imm = _parse_imm(toks[1], 8, lineno)
            word = (opcode << 12) | (rd << 8) | (imm & 0xFF)
        elif op.type == "B":
            if len(toks) != 2:
                raise AsmError(f"line {lineno}: {mnemonic} expects 2 operands")
            nzp = _parse_imm(toks[0], 3, lineno)
            target = _parse_imm(toks[1], 9, lineno, labels=labels)
            word = (opcode << 12) | (nzp << 9) | (target & 0x1FF)
        else:
            raise AsmError(f"line {lineno}: unsupported op type '{op.type}'")
        words.append(word & 0xFFFF)
    return words


def to_hex(words: Iterable[int]) -> str:
    return "".join(f"{w & 0xFFFF:04x}\n" for w in words)


def main(argv: list[str] | None = None) -> int:
    desc = (__doc__ or "").splitlines()[0]
    p = argparse.ArgumentParser(prog="opengpu-asm", description=desc)
    p.add_argument("source", type=Path, help="input .asm file")
    p.add_argument("-o", "--output", type=Path, required=True, help="output .hex file")
    args = p.parse_args(argv)
    try:
        words = assemble(args.source.read_text())
    except AsmError as e:
        print(f"asm error: {e}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(to_hex(words))
    print(f"wrote {len(words)} words -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
