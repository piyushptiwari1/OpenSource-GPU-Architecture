# ISA codegen

The canonical ISA spec lives in
[`docs/isa/instructions.yaml`](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/blob/main/docs/isa/instructions.yaml).
Three artefacts are generated from it:

| Artefact | Path | Consumer |
|----------|------|----------|
| C++ decode table | `sim/cppref/include/opengpu/isa_table.hpp` | C++ reference simulator |
| customasm grammar | `tools/asm/opengpu.asm` | hex assembler |
| Markdown reference | `docs/isa/reference.md` | this site |

CI runs `python -m tools.codegen.regen --check` and fails any PR that
hand-edits a generated file or forgets to re-run the codegen after
changing the YAML.

## Regenerate locally

```bash
python -m tools.codegen.regen           # write outputs
python -m tools.codegen.regen --check   # CI mode: exit 1 on drift
```

## Adding a new instruction

1. Edit `docs/isa/instructions.yaml`. Pick an unused opcode (`0x0`–`0xF`),
   give it an encoding `type` (`R`, `I`, `B`, `Z`), document `syntax`
   and `semantics`, and list the `control` signals it asserts.
2. Add the matching case to `src/decoder.sv`. The control-signal names
   must match the YAML exactly — the loader fails fast otherwise.
3. Run `python -m tools.codegen.regen`. The C++ table, the asm
   grammar, and the [ISA reference page](../isa/reference.md) are
   refreshed automatically.
4. Add a Catch2 test in `sim/cppref/tests/` and a cocotb test in
   `test/` if the instruction has non-trivial semantics.
5. `python -m tools.codegen.regen --check` should exit clean before you
   commit.

## API

::: tools.codegen.isa_loader
    options:
      heading_level: 3
      show_source: false

::: tools.codegen.regen
    options:
      heading_level: 3
      show_source: false

::: tools.codegen.render_isa_md
    options:
      heading_level: 3
      show_source: false
