"""Regenerate ISA-derived files from ``docs/isa/instructions.yaml``.

CLI:
    python -m tools.codegen.regen           # write outputs
    python -m tools.codegen.regen --check   # fail (exit 1) if outputs would change

The ``--check`` mode is what CI runs: it ensures contributors regenerate
artefacts whenever the YAML changes, instead of hand-editing them.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from dataclasses import dataclass
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, StrictUndefined

from . import isa_loader, render_isa_md

REPO_ROOT = Path(__file__).resolve().parents[2]
ISA_YAML = REPO_ROOT / "docs" / "isa" / "instructions.yaml"
TEMPLATE_DIR = Path(__file__).resolve().parent / "templates"


@dataclass(frozen=True)
class Target:
    template: str
    output: Path


TARGETS: tuple[Target, ...] = (
    Target(
        template="isa_table.hpp.j2",
        output=REPO_ROOT / "sim" / "cppref" / "include" / "opengpu" / "isa_table.hpp",
    ),
    Target(
        template="opengpu.asm.j2",
        output=REPO_ROOT / "tools" / "asm" / "opengpu.asm",
    ),
)


def _render_all() -> dict[Path, str]:
    isa = isa_loader.load(ISA_YAML)
    source_sha256 = hashlib.sha256(ISA_YAML.read_bytes()).hexdigest()

    env = Environment(
        loader=FileSystemLoader(str(TEMPLATE_DIR)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=False,
        lstrip_blocks=False,
    )

    rendered: dict[Path, str] = {}
    for tgt in TARGETS:
        template = env.get_template(tgt.template)
        rendered[tgt.output] = template.render(isa=isa, source_sha256=source_sha256)

    # Markdown ISA reference is rendered programmatically (no Jinja).
    rendered[render_isa_md.OUTPUT] = render_isa_md.render(ISA_YAML)
    return rendered


def _write(rendered: dict[Path, str]) -> None:
    for path, text in rendered.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def _check(rendered: dict[Path, str]) -> int:
    drift: list[Path] = []
    for path, text in rendered.items():
        actual = path.read_text(encoding="utf-8") if path.exists() else ""
        if actual != text:
            drift.append(path)
    if drift:
        rel = ", ".join(str(p.relative_to(REPO_ROOT)) for p in drift)
        sys.stderr.write(
            "ISA codegen out of date for: " + rel + "\nRun: python -m tools.codegen.regen\n"
        )
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if any generated file would change",
    )
    args = p.parse_args(argv)

    rendered = _render_all()
    if args.check:
        return _check(rendered)
    _write(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
