"""OpenGPU ISA codegen.

Single source of truth: ``docs/isa/instructions.yaml``.
Drives the C++ reference simulator decode tables and the customasm grammar.
"""

from __future__ import annotations

__all__ = ["isa_loader"]
