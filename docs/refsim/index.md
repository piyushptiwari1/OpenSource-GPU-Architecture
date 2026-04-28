# C++ reference simulator (`opengpu-refsim`)

A deterministic golden model of the OpenGPU 16-bit ISA. Used for
Catch2 unit tests, the [DiffTest harness](../tooling/difftest.md), and
documentation. Source: [`sim/cppref/`](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/tree/main/sim/cppref).

## Build

```bash
cmake -S sim/cppref -B build/cppref -G Ninja
cmake --build build/cppref
ctest --test-dir build/cppref --output-on-failure
```

The toolchain image
(`ghcr.io/piyushptiwari1/opengpu-toolchain:latest`) already ships GCC
13, CMake ≥ 3.28 and Ninja. Catch2 is fetched on first build via CMake
`FetchContent`. `OPENGPU_REFSIM_WERROR=ON` is the default — `gcc` and
`clang` are both clean under the full warning set.

## Run

```bash
./build/cppref/opengpu-refsim \
    --program program.hex \
    --data    data.hex     \
    --threads 8            \
    --blocks  1            \
    --trace   trace.jsonl  \
    --max-steps 200
```

`trace.jsonl` is line-delimited JSON, one record per retired
instruction. This is the format consumed by the [DiffTest
harness](../tooling/difftest.md).

## Trace schema

Each line of `trace.jsonl` looks like:

```json
{"tick":0,"tid":0,"pc":0,"instr":20480,"op":"MUL","rd":0,
 "rd_val":0,"mem_w":null,"nzp":0,"done":false}
```

| Field | Type | Meaning |
|-------|------|---------|
| `tick`   | int        | refsim cycle counter |
| `tid`    | int        | thread id within the kernel grid |
| `pc`     | int        | program counter at retire |
| `instr`  | int        | 16-bit instruction word |
| `op`     | string     | mnemonic (matches ISA YAML) |
| `rd`     | int / null | destination register, `null` if no write |
| `rd_val` | int / null | value written to `rd`, `null` if no write |
| `mem_w`  | object / null | `{"addr":A,"data":D}` for `STR`, else `null` |
| `nzp`    | int        | NZP flags after the insn (3 bits) |
| `done`   | bool       | thread asserted `done` this cycle |

## What the tests cover

- **Decode field layout** — `instr[15:12] = opcode`, R-type fields,
  I-type immediate, B-type NZP + target.
- **ALU edge cases** — DIV-by-zero returns 0, ADD wraps at 8 bits.
- **CMP NZP semantics** — exactly one of N, Z, P is set per result.
- **System registers** — `R15` reads back per-thread `threadIdx`.
- **End-to-end matadd-8** — same program/data as the cocotb
  `test_matadd.py`, asserts every output element matches the
  reference sum.
