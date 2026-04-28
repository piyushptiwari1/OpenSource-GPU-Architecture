"""DiffTest: lockstep equivalence check between RTL (cocotb) and the
C++ reference simulator (``opengpu-refsim``).

Design
------
* The refsim emits one **JSON line per retired instruction** to its trace
  file (see ``sim/cppref/src/trace.cpp``). Each record looks like::

      {"tick":N,"tid":T,"pc":P,"instr":I,"op":"ADD",
       "rd":1,"rd_val":42,"mem_w":null,"nzp":0,"done":false}

* On the cocotb side, an integration writes one record per retired
  instruction with the **same schema**.  ``DiffStream`` walks the two
  streams in lockstep keyed on ``(tick, tid)`` and raises
  :class:`DiffMismatch` on the first divergence, with full context.

* This module deliberately knows nothing about the cocotb fixtures - it
  just consumes two JSONL streams.  That keeps the harness usable from
  unit tests, CI, and ad-hoc debugging.
"""

from __future__ import annotations

import dataclasses
import json
import subprocess
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any

__all__ = [
    "DiffMismatch",
    "RetireRecord",
    "diff_streams",
    "iter_jsonl",
    "run_refsim",
]


# Fields whose mismatch is considered a real divergence.  ``tick`` itself
# is not checked - the two simulators may run on different clock grids
# and we align by retired-instruction order per thread.
COMPARED_FIELDS: tuple[str, ...] = (
    "pc",
    "instr",
    "op",
    "rd",
    "rd_val",
    "mem_w",
    "nzp",
    "done",
)


@dataclasses.dataclass(frozen=True)
class RetireRecord:
    """One retired instruction from either RTL or refsim."""

    tid: int
    pc: int
    instr: int
    op: str
    rd: int | None
    rd_val: int | None
    mem_w: dict[str, int] | None  # {"addr": A, "data": D} or None
    nzp: int
    done: bool

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> RetireRecord:
        return cls(
            tid=int(d["tid"]),
            pc=int(d["pc"]),
            instr=int(d["instr"]),
            op=str(d["op"]),
            rd=None if d.get("rd") is None else int(d["rd"]),
            rd_val=None if d.get("rd_val") is None else int(d["rd_val"]),
            mem_w=d.get("mem_w"),
            nzp=int(d.get("nzp", 0)),
            done=bool(d.get("done", False)),
        )


class DiffMismatch(AssertionError):
    """Raised on the first RTL/refsim divergence.

    The message contains the offending field and both records, which is
    typically enough for a developer to localise the bug to a single
    instruction.
    """

    def __init__(
        self,
        *,
        field: str,
        rtl: RetireRecord,
        ref: RetireRecord,
        index: int,
    ) -> None:
        super().__init__(
            f"DiffTest mismatch at retire #{index} field={field!r}\n  RTL: {rtl}\n  REF: {ref}"
        )
        self.field = field
        self.rtl = rtl
        self.ref = ref
        self.index = index


def iter_jsonl(path: Path | str) -> Iterator[RetireRecord]:
    """Stream records from a JSONL trace file.

    Blank lines are ignored so that the same parser works on
    refsim output and on hand-crafted golden traces.
    """
    p = Path(path)
    with p.open("r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            yield RetireRecord.from_dict(json.loads(line))


def run_refsim(
    refsim: Path | str,
    *,
    program: Path | str,
    data: Path | str | None = None,
    threads: int,
    blocks: int = 1,
    trace: Path | str,
    max_steps: int = 10_000,
    mem_size: int | None = None,
) -> None:
    """Invoke ``opengpu-refsim`` and write its trace to ``trace``.

    Parameters mirror the CLI in ``sim/cppref/src/main.cpp``.  Raises
    :class:`subprocess.CalledProcessError` if refsim exits non-zero so
    cocotb tests fail fast on backend errors.
    """
    cmd: list[str] = [
        str(refsim),
        "--program",
        str(program),
        "--threads",
        str(threads),
        "--blocks",
        str(blocks),
        "--trace",
        str(trace),
        "--max-steps",
        str(max_steps),
    ]
    if data is not None:
        cmd += ["--data", str(data)]
    if mem_size is not None:
        cmd += ["--mem-size", str(mem_size)]
    subprocess.run(cmd, check=True)


def diff_streams(
    rtl: Iterable[RetireRecord],
    ref: Iterable[RetireRecord],
    *,
    fields: tuple[str, ...] = COMPARED_FIELDS,
) -> int:
    """Compare two retire streams in lockstep.

    Returns the number of records compared.  Raises
    :class:`DiffMismatch` on the first field divergence and
    :class:`AssertionError` if one stream is shorter than the other.
    """
    rtl_list = list(rtl)
    ref_list = list(ref)
    if len(rtl_list) != len(ref_list):
        raise AssertionError(
            f"DiffTest length mismatch: rtl={len(rtl_list)} ref={len(ref_list)} "
            f"(first extra rtl={rtl_list[len(ref_list) :][:1]!r} "
            f"ref={ref_list[len(rtl_list) :][:1]!r})"
        )
    for index, (r, e) in enumerate(zip(rtl_list, ref_list, strict=True)):
        for f in fields:
            if getattr(r, f) != getattr(e, f):
                raise DiffMismatch(field=f, rtl=r, ref=e, index=index)
    return len(rtl_list)
