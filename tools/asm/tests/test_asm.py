"""Unit tests for the in-house Python assembler."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.asm.asm import AsmError, assemble


def test_z_type() -> None:
    assert assemble("NOP\nRET\n") == [0x0000, 0xF000]


def test_const_imm_decimal_and_hex() -> None:
    words = assemble("CONST R3, #42\nCONST R4, 0xFF\n")
    # opcode=9, rd, imm
    assert words == [(0x9 << 12) | (3 << 8) | 42, (0x9 << 12) | (4 << 8) | 0xFF]


def test_r_type_three_operand() -> None:
    [w] = assemble("ADD R1, R2, R3\n")
    assert w == (0x3 << 12) | (1 << 8) | (2 << 4) | 3


def test_str_two_operand_zero_rd() -> None:
    [w] = assemble("STR R5, R6\n")
    # opcode=8, rd field=0, rs=5, rt=6
    assert w == (0x8 << 12) | (0 << 8) | (5 << 4) | 6


def test_ldr_layout() -> None:
    [w] = assemble("LDR R2, R7\n")
    # opcode=7, rd=2, rs=7, rt=0
    assert w == (0x7 << 12) | (2 << 8) | (7 << 4) | 0


def test_register_aliases() -> None:
    [w] = assemble("ADD R0, %threadIdx, %blockIdx\n")
    assert w == (0x3 << 12) | (0 << 8) | (15 << 4) | 13


def test_branch_with_label() -> None:
    src = """
        CONST R0, #0
    loop:
        CONST R1, #1
        BRnzp nzp, loop
        RET
    """
    words = assemble(src)
    # loop is the second instruction (PC=1)
    br = words[2]
    assert (br >> 12) & 0xF == 0x1
    assert (br >> 9) & 0x7 == 0b111  # nzp mnemonic = all bits
    assert br & 0x1FF == 1


def test_comment_does_not_eat_immediate_prefix() -> None:
    # ``#`` must NOT be treated as a comment marker (conflicts with #imm).
    [w] = assemble("CONST R0, #123  ; this is a comment\n")
    assert w == (0x9 << 12) | (0 << 8) | 123


def test_unknown_mnemonic() -> None:
    with pytest.raises(AsmError, match="unknown mnemonic"):
        assemble("XYZZY R0, R1\n")


def test_imm_out_of_range() -> None:
    with pytest.raises(AsmError, match="out of"):
        assemble("CONST R0, #300\n")


def test_duplicate_label() -> None:
    with pytest.raises(AsmError, match="duplicate label"):
        assemble("foo: NOP\nfoo: RET\n")
