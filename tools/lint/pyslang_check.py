#!/usr/bin/env python3
"""SystemVerilog parse-only check using pyslang.

Used by the lint CI job. Reports diagnostics from the slang frontend
across all listed source files together (so cross-file references
resolve).

Exit status: 0 on success (no errors); 1 if any error-severity
diagnostic is emitted. Warnings are logged but do not affect the
exit status (the CI step itself decides whether to treat warnings
as failures).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pyslang


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "files",
        nargs="+",
        type=Path,
        help="SystemVerilog source files (.sv, .svh, .v, .vh).",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress per-file 'parsed' messages.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    missing = [f for f in args.files if not f.is_file()]
    if missing:
        print(f"error: {len(missing)} file(s) not found:", file=sys.stderr)
        for f in missing:
            print(f"  {f}", file=sys.stderr)
        return 2

    tree = pyslang.SyntaxTree.fromFiles([str(f) for f in args.files])

    compilation = pyslang.Compilation()
    compilation.addSyntaxTree(tree)

    diags = compilation.getAllDiagnostics()
    engine = pyslang.DiagnosticEngine(compilation.sourceManager)
    client = pyslang.TextDiagnosticClient()
    engine.addClient(client)

    error_count = 0
    warning_count = 0
    error_severities = {
        pyslang.DiagnosticSeverity.Error,
        pyslang.DiagnosticSeverity.Fatal,
    }
    for diag in diags:
        engine.issue(diag)
        sev = engine.getSeverity(diag.code, diag.location)
        if sev in error_severities:
            error_count += 1
        elif sev == pyslang.DiagnosticSeverity.Warning:
            warning_count += 1

    output = client.getString()
    if output:
        sys.stderr.write(output)

    if not args.quiet:
        print(
            f"pyslang: parsed {len(args.files)} file(s); "
            f"errors={error_count}, warnings={warning_count}"
        )

    return 1 if error_count > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
