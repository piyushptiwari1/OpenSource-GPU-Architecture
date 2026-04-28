"""OpenGPU backend stub for tinygrad.

Status: experimental. This module ships a single, manually-lowered kernel
template (``vecadd``) and a tiny dispatch adapter that runs it on the C++
reference simulator. It exists to:

1. Validate that the OpenGPU ISA is expressive enough for a real ML
   framework's lowering target.
2. Give downstream contributors a concrete, runnable starting point for a
   full ``UOp``-graph lowering (tracked under C-16 in the integration plan).

What this is NOT
----------------
- It is not a tinygrad ``Buffer`` / ``Runtime`` / ``Renderer``
  implementation. Wiring into ``tinygrad.runtime.ops_*`` is intentionally
  deferred until the upstream ``UOp`` API stabilises.
- It does not depend on ``tinygrad`` at import time. The dependency is
  optional; importing this module is safe in CI without it.

Usage
-----
    from tools.tinygrad_opengpu.codegen import emit_vecadd
    asm = emit_vecadd(n=4)
    # ... feed asm into tools.asm.asm.assemble or write to disk.
"""
