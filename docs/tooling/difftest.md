# DiffTest harness

`tools/difftest/` compares two retire-instruction streams in lockstep:
the RTL (cocotb) and the C++ reference simulator. The first
divergence aborts the test with a precise message:

```
DiffTest mismatch at retire #42 field='rd_val'
  RTL: RetireRecord(tid=2, pc=12, instr=0x4422, op='ADD', rd=2, rd_val=9, ...)
  REF: RetireRecord(tid=2, pc=12, instr=0x4422, op='ADD', rd=2, rd_val=8, ...)
```

## Workflow

1. Run a kernel through the [reference simulator](../refsim/index.md)
   with `--trace ref.jsonl`.
2. From the cocotb test, write one matching JSON record per retired
   instruction (same schema; see [Trace schema](../refsim/index.md#trace-schema)).
3. Call `diff_streams(iter_jsonl(rtl), iter_jsonl(ref))`.

```python
from tools.difftest import diff_streams, iter_jsonl, run_refsim

run_refsim(
    "build/cppref/opengpu-refsim",
    program="program.hex",
    data="data.hex",
    threads=8,
    trace="ref.jsonl",
)
n = diff_streams(iter_jsonl("rtl.jsonl"), iter_jsonl("ref.jsonl"))
print(f"DiffTest OK ({n} records compared)")
```

## API

::: tools.difftest
    options:
      heading_level: 3
      show_source: false
      members:
        - RetireRecord
        - DiffMismatch
        - iter_jsonl
        - run_refsim
        - diff_streams
