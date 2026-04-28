"""Run all OpenGPU benchmarks under bench/kernels/* through opengpu-refsim.

For each kernel:
  1. Assemble ``kernel.asm`` -> ``build/<name>/kernel.hex`` via tools.asm.asm.
  2. Materialize input bytes from ``host.input_data()`` -> ``data.hex``.
  3. Run ``opengpu-refsim --program ... --data ... --mem-dump out.hex``.
  4. Parse retired-instruction count from stdout and final memory from dump.
  5. Compare against ``host.golden(initial)``.

Emits ``bench/results/results.json`` with per-kernel pass/fail and metrics.
Exits non-zero if any kernel fails verification, gating CI.

The runner is intentionally subprocess-based so the C++ refsim stays the
single execution model: no parallel "Python interpreter for the ISA" to
drift from RTL/cppref parity.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
KERNELS_DIR = REPO_ROOT / "bench" / "kernels"
BUILD_DIR = REPO_ROOT / "build" / "bench"
RESULTS_DIR = REPO_ROOT / "bench" / "results"
DEFAULT_REFSIM = REPO_ROOT / "sim" / "cppref" / "build" / "opengpu-refsim"

RETIRED_RE = re.compile(r"^retired_instructions=(\d+)\s*$", re.MULTILINE)


@dataclass
class KernelResult:
    name: str
    passed: bool
    retired_instructions: int
    mismatches: list[str]
    threads: int
    blocks: int


def _load_host_module(host_py: Path):
    spec = importlib.util.spec_from_file_location(f"bench_host_{host_py.parent.name}", host_py)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {host_py}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _write_data_hex(path: Path, data: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{b & 0xFF:02x}\n" for b in data))


def _read_mem_dump(path: Path) -> list[int]:
    out: list[int] = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            out.append(int(line, 16))
    return out


def _assemble(asm_path: Path, hex_path: Path) -> None:
    # Run the in-tree assembler as a module; this exercises the same code
    # path users would invoke on the CLI (no private API).
    cmd = [sys.executable, "-m", "tools.asm.asm", str(asm_path), "-o", str(hex_path)]
    subprocess.run(cmd, check=True, cwd=REPO_ROOT)


def run_kernel(name: str, refsim: Path) -> KernelResult:
    kdir = KERNELS_DIR / name
    asm = kdir / "kernel.asm"
    host = _load_host_module(kdir / "host.py")

    build = BUILD_DIR / name
    build.mkdir(parents=True, exist_ok=True)
    prog_hex = build / "kernel.hex"
    data_hex = build / "data.hex"
    mem_dump = build / "mem_out.hex"

    _assemble(asm, prog_hex)
    initial = list(host.input_data())
    _write_data_hex(data_hex, initial)

    cmd = [
        str(refsim),
        "--program",
        str(prog_hex),
        "--data",
        str(data_hex),
        "--threads",
        str(host.N),
        "--blocks",
        str(host.BLOCKS),
        "--mem-size",
        str(host.MEM_SIZE),
        "--mem-dump",
        str(mem_dump),
    ]
    proc = subprocess.run(cmd, check=True, capture_output=True, text=True, cwd=REPO_ROOT)
    m = RETIRED_RE.search(proc.stdout)
    retired = int(m.group(1)) if m else -1

    final_mem = _read_mem_dump(mem_dump)
    expected = host.golden(initial)
    mismatches: list[str] = []
    for addr, want in expected.items():
        got = final_mem[addr] if addr < len(final_mem) else None
        if got != (want & 0xFF):
            mismatches.append(f"mem[{addr}]: got={got} want={want}")

    return KernelResult(
        name=name,
        passed=not mismatches,
        retired_instructions=retired,
        mismatches=mismatches,
        threads=host.N,
        blocks=host.BLOCKS,
    )


def discover() -> list[str]:
    return sorted(p.name for p in KERNELS_DIR.iterdir() if (p / "kernel.asm").is_file())


def main(argv: list[str] | None = None) -> int:
    desc = (__doc__ or "").splitlines()[0]
    p = argparse.ArgumentParser(description=desc)
    default_refsim = Path(os.environ.get("OPENGPU_REFSIM", str(DEFAULT_REFSIM)))
    p.add_argument("--refsim", type=Path, default=default_refsim)
    p.add_argument("--filter", default=None, help="regex; only run matching kernels")
    p.add_argument("--results", type=Path, default=RESULTS_DIR / "results.json")
    args = p.parse_args(argv)

    if not args.refsim.is_file():
        print(f"refsim binary not found: {args.refsim}", file=sys.stderr)
        return 2

    flt = re.compile(args.filter) if args.filter else None
    names = [n for n in discover() if flt is None or flt.search(n)]
    if not names:
        print("no kernels matched", file=sys.stderr)
        return 2

    results: list[KernelResult] = []
    for name in names:
        r = run_kernel(name, args.refsim)
        status = "PASS" if r.passed else "FAIL"
        print(
            f"[{status}] {r.name:<14} retired={r.retired_instructions:<6} "
            f"threads={r.threads} blocks={r.blocks}"
        )
        for msg in r.mismatches:
            print(f"        {msg}")
        results.append(r)

    args.results.parent.mkdir(parents=True, exist_ok=True)
    args.results.write_text(json.dumps([asdict(r) for r in results], indent=2) + "\n")
    failures = [r for r in results if not r.passed]
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
