# OpenGPU codegen

This package owns the translation from `docs/isa/instructions.yaml` (single
source of truth for the ISA) to derived artefacts:

| Output                                              | Purpose                                  |
|-----------------------------------------------------|------------------------------------------|
| `sim/cppref/include/opengpu/isa_table.hpp`          | Decode/encode tables for the C++ refsim. |
| `tools/asm/opengpu.asm`                             | customasm grammar (Phase-0 assembler).   |
| `docs/isa/index.md`                                 | mkdocs page (added in Step 5/C-12).      |

## Usage

```
python -m tools.codegen.regen          # regenerate everything
python -m tools.codegen.regen --check  # CI mode: fail if outputs would change
```

The `--check` mode is what `lint.yml` will eventually run so a contributor
who hand-edits a generated file gets a hard error.

## Layout

```
tools/codegen/
    __init__.py
    regen.py                # CLI
    isa_loader.py           # YAML -> typed Python objects, with validation
    templates/
        isa_table.hpp.j2
        opengpu.asm.j2
```

No file in this directory is auto-generated.
