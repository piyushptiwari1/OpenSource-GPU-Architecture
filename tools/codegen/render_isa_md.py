"""Render the canonical ISA YAML to a Markdown reference page.

Output: ``docs/isa/reference.md`` (consumed by mkdocs build).

This page is generated. CI re-runs the renderer with ``--check`` and
fails if the checked-in copy drifts (mirrors the codegen --check
pattern used for the C++ table and the customasm ruleset).
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from io import StringIO
from pathlib import Path

from . import isa_loader

REPO_ROOT = Path(__file__).resolve().parents[2]
ISA_YAML = REPO_ROOT / "docs" / "isa" / "instructions.yaml"
OUTPUT = REPO_ROOT / "docs" / "isa" / "reference.md"

_TYPE_LAYOUTS: dict[str, str] = {
    "R": "[15:12]=opcode | [11:8]=Rd | [7:4]=Rs | [3:0]=Rt",
    "I": "[15:12]=opcode | [11:8]=Rd | [7:0]=imm8",
    "B": "[15:12]=opcode | [11:9]=nzp | [8:0]=target",
    "Z": "[15:12]=opcode | [11:0]=0  (NOP / RET)",
}


def _emit(out: StringIO, isa: isa_loader.Isa, source_sha: str) -> None:
    types_used = sorted({i.type for i in isa.instructions})

    out.write("# ISA reference\n\n")
    out.write(
        '!!! info "Generated"\n'
        "    This page is rendered from "
        "[`docs/isa/instructions.yaml`](https://github.com/piyushptiwari1/"
        "OpenSource-GPU-Architecture/blob/main/docs/isa/instructions.yaml) "
        "by `tools/codegen/render_isa_md.py`. Edit the YAML, not this file.\n\n"
    )
    out.write(f"`SHA-256(instructions.yaml)` = `{source_sha}`\n\n")

    out.write("## Overview\n\n")
    out.write(
        f"OpenGPU (`{isa.name}`, ISA version {isa.version}) is a "
        f"**{isa.word_bits}-bit** instruction-width SIMT machine with an "
        f"**{isa.data_bits}-bit** register / data path and an "
        f"**{isa.addr_bits}-bit** unified address space. It defines "
        f"{len(isa.instructions)} instructions across "
        f"{len(types_used)} encoding classes "
        f"({', '.join(types_used)}).\n\n"
    )

    out.write("## Register file\n\n")
    out.write(
        f"{isa.num_registers} general-purpose {isa.data_bits}-bit "
        f"registers per thread, plus a {isa.nzp_bits}-bit NZP flag "
        f"register written by `CMP` and consumed by `BRnzp`.\n\n"
    )
    out.write("| ID | Name | Alias | Read-only |\n")
    out.write("|----|------|-------|:---------:|\n")
    for r in isa.registers:
        alias = f"`%{r.alias}`" if r.alias else "—"
        ro = "✓" if r.readonly else ""
        out.write(f"| `{r.id}` | `{r.name}` | {alias} | {ro} |\n")
    out.write("\n")

    out.write("## Encoding classes\n\n")
    out.write("| Type | Layout (`instr[15:0]`) |\n")
    out.write("|------|------------------------|\n")
    for ty in types_used:
        out.write(f"| `{ty}` | `{_TYPE_LAYOUTS.get(ty, '?')}` |\n")
    out.write("\n")

    out.write("## Control signals\n\n")
    out.write(
        "Every instruction emits a fixed bundle of control signals "
        "(mirrors `src/decoder.sv` outputs). Bits not listed default to "
        "zero. The C++ reference simulator decodes the same bundle from "
        "the auto-generated `sim/cppref/include/opengpu/isa_table.hpp`.\n\n"
    )
    out.write("| Signal | Width |\n")
    out.write("|--------|:-----:|\n")
    for cs in isa.control_signals:
        out.write(f"| `{cs.name}` | {cs.width} |\n")
    out.write("\n")

    out.write("## Instructions\n\n")
    for ins in sorted(isa.instructions, key=lambda i: i.opcode):
        out.write(f"### `{ins.mnemonic}` — opcode `0x{ins.opcode:X}` ({ins.type}-type)\n\n")
        out.write(f"- **Syntax:** `{ins.syntax}`\n")
        out.write(f"- **Semantics:** {ins.semantics}\n")
        if ins.control:
            sigs = ", ".join(f"`{k}={v}`" for k, v in sorted(ins.control.items()))
            out.write(f"- **Control:** {sigs}\n")
        out.write("\n")


def render(isa_yaml: Path = ISA_YAML) -> str:
    isa = isa_loader.load(isa_yaml)
    source_sha = hashlib.sha256(isa_yaml.read_bytes()).hexdigest()
    buf = StringIO()
    _emit(buf, isa, source_sha)
    return buf.getvalue()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--check",
        action="store_true",
        help="Fail if docs/isa/reference.md is out of date.",
    )
    args = p.parse_args(argv)

    rendered = render()
    if args.check:
        existing = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if existing != rendered:
            sys.stderr.write(
                "docs/isa/reference.md is out of date.\n"
                "Run: python -m tools.codegen.render_isa_md\n"
            )
            return 1
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
"""Render the canonical ISA YAML to a Markdown reference page.

Output:  docs/isa/reference.md  (consumed by mkdocs build).

This page is *generated*; CI re-runs the renderer and fails if the
checked-in copy drifts (mirrors the codegen --check pattern used for
the C++ table and the customasm ruleset).
"""
