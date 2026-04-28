# OpenGPU C++ reference simulator (`opengpu-refsim`)

A deterministic golden model of the OpenGPU 16-bit ISA. Used for:

1. **Catch2 unit/property tests** — every refactor of the RTL has a sane
   reference to diff against.
2. **DiffTest** (`tools/difftest/cocotb_diff.py`) — runs the RTL in cocotb
   and the refsim in lockstep, comparing register file + memory state on
   every retired instruction. First divergence aborts the test with a
   precise log entry.
3. **Documentation/examples** — the refsim is also a reference
   implementation of the ISA semantics.

## Build

```bash
cmake -S sim/cppref -B build/cppref -G Ninja
cmake --build build/cppref
ctest --test-dir build/cppref --output-on-failure
```

The toolchain image (`ghcr.io/piyushptiwari1/opengpu-toolchain:latest`)
already ships GCC 13, CMake ≥ 3.28, Ninja, and Catch2 will be fetched on
first build via CMake `FetchContent`.

## Running

```bash
./build/cppref/opengpu-refsim \
    --program program.hex \
    --data    data.hex     \
    --threads 8            \
    --trace   trace.jsonl
```

`trace.jsonl` is line-delimited JSON, one record per retired instruction.
This is the format consumed by the DiffTest harness.

## Layout

```
sim/cppref/
    include/opengpu/
        isa_table.hpp     # AUTO-GENERATED from docs/isa/instructions.yaml
        memory.hpp
        thread.hpp
        core.hpp
        loader.hpp
        trace.hpp
    src/
        memory.cpp
        thread.cpp
        core.cpp
        loader.cpp
        trace.cpp
        main.cpp
    tests/
        test_decode.cpp
        test_alu.cpp
        test_kernel.cpp
```

The only file in `include/opengpu/` that should ever change automatically
is `isa_table.hpp`. Everything else is hand-written and committed.
