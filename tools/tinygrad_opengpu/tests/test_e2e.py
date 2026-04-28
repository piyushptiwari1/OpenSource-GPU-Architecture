"""End-to-end test: tinygrad-opengpu codegen -> asm -> refsim -> verify."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
REFSIM = REPO_ROOT / "sim" / "cppref" / "build" / "opengpu-refsim"

sys.path.insert(0, str(REPO_ROOT))
from tools.asm.asm import assemble, to_hex  # noqa: E402  -- after sys.path
from tools.tinygrad_opengpu.codegen import emit_elementwise  # noqa: E402


@pytest.mark.skipif(not REFSIM.is_file(), reason="refsim binary not built")
@pytest.mark.parametrize(
    "op,a,b,expected",
    [
        ("add", [1, 2, 3, 4], [10, 20, 30, 40], [11, 22, 33, 44]),
        ("sub", [50, 40, 30, 20], [1, 2, 3, 4], [49, 38, 27, 16]),
        ("mul", [2, 3, 4, 5], [3, 4, 5, 6], [6, 12, 20, 30]),
    ],
)
def test_elementwise_end_to_end(
    tmp_path: Path,
    op: str,
    a: list[int],
    b: list[int],
    expected: list[int],
) -> None:
    n = len(a)
    asm = emit_elementwise(op, n)
    words = assemble(asm)
    prog = tmp_path / "k.hex"
    prog.write_text(to_hex(words))

    mem_in = a + b + [0] * n + [0] * (32 - 3 * n)
    data = tmp_path / "d.hex"
    data.write_text("".join(f"{v & 0xFF:02x}\n" for v in mem_in))

    out = tmp_path / "m.hex"
    subprocess.run(
        [
            str(REFSIM),
            "--program",
            str(prog),
            "--data",
            str(data),
            "--threads",
            str(n),
            "--blocks",
            "1",
            "--mem-size",
            "32",
            "--mem-dump",
            str(out),
        ],
        check=True,
        capture_output=True,
    )
    final = [int(line, 16) for line in out.read_text().splitlines() if line.strip()]
    got = final[2 * n : 3 * n]
    assert got == [v & 0xFF for v in expected], f"op={op}: got={got} want={expected}"


def test_emit_rejects_bad_op() -> None:
    with pytest.raises(ValueError):
        emit_elementwise("xor", 4)


def test_emit_rejects_oversize() -> None:
    with pytest.raises(ValueError):
        emit_elementwise("add", 100)
