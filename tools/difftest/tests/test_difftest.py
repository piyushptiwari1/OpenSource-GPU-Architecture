"""Self-tests for the DiffTest stream comparator.

Runs as part of the ``isa-codegen-check`` job (any plain Python pytest in
``tools/`` is picked up).  No RTL or refsim binary required - we feed the
comparator hand-crafted JSONL streams.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.difftest import (
    DiffMismatch,
    RetireRecord,
    diff_streams,
    iter_jsonl,
)


def _write(tmp_path: Path, name: str, records: list[dict]) -> Path:
    p = tmp_path / name
    p.write_text("\n".join(json.dumps(r) for r in records) + "\n")
    return p


def _rec(**kw) -> dict:
    base = {
        "tick": 0,
        "tid": 0,
        "pc": 0,
        "instr": 0,
        "op": "ADD",
        "rd": 1,
        "rd_val": 0,
        "mem_w": None,
        "nzp": 0,
        "done": False,
    }
    base.update(kw)
    return base


def test_matching_streams_are_equal(tmp_path: Path) -> None:
    a = [_rec(pc=0, rd_val=1), _rec(pc=2, rd_val=3, done=True)]
    n = diff_streams(
        iter_jsonl(_write(tmp_path, "a.jsonl", a)),
        iter_jsonl(_write(tmp_path, "b.jsonl", a)),
    )
    assert n == 2


def test_field_mismatch_raises(tmp_path: Path) -> None:
    a = [_rec(pc=0, rd_val=1)]
    b = [_rec(pc=0, rd_val=2)]
    with pytest.raises(DiffMismatch) as exc:
        diff_streams(
            iter_jsonl(_write(tmp_path, "a.jsonl", a)),
            iter_jsonl(_write(tmp_path, "b.jsonl", b)),
        )
    assert exc.value.field == "rd_val"
    assert exc.value.index == 0


def test_length_mismatch_raises(tmp_path: Path) -> None:
    a = [_rec(), _rec(pc=2)]
    b = [_rec()]
    with pytest.raises(AssertionError) as exc:
        diff_streams(
            iter_jsonl(_write(tmp_path, "a.jsonl", a)),
            iter_jsonl(_write(tmp_path, "b.jsonl", b)),
        )
    assert "length mismatch" in str(exc.value)


def test_record_parses_optionals() -> None:
    r = RetireRecord.from_dict(_rec(rd=None, rd_val=None, mem_w={"addr": 4, "data": 9}))
    assert r.rd is None
    assert r.rd_val is None
    assert r.mem_w == {"addr": 4, "data": 9}
