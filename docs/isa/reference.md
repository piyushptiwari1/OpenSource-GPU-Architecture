# ISA reference

!!! info "Generated"
    This page is rendered from [`docs/isa/instructions.yaml`](https://github.com/piyushptiwari1/OpenSource-GPU-Architecture/blob/main/docs/isa/instructions.yaml) by `tools/codegen/render_isa_md.py`. Edit the YAML, not this file.

`SHA-256(instructions.yaml)` = `9e27eb5918cf8cd82ece0fb7d318a65c184af7acd7b5fcecf4acfe71b9c33c8f`

## Overview

OpenGPU (`opengpu`, ISA version 1) is a **16-bit** instruction-width SIMT machine with an **8-bit** register / data path and an **8-bit** unified address space. It defines 12 instructions across 4 encoding classes (B, I, R, Z).

## Register file

16 general-purpose 8-bit registers per thread, plus a 3-bit NZP flag register written by `CMP` and consumed by `BRnzp`.

| ID | Name | Alias | Read-only |
|----|------|-------|:---------:|
| `0` | `R0` | — |  |
| `1` | `R1` | — |  |
| `2` | `R2` | — |  |
| `3` | `R3` | — |  |
| `4` | `R4` | — |  |
| `5` | `R5` | — |  |
| `6` | `R6` | — |  |
| `7` | `R7` | — |  |
| `8` | `R8` | — |  |
| `9` | `R9` | — |  |
| `10` | `R10` | — |  |
| `11` | `R11` | — |  |
| `12` | `R12` | — |  |
| `13` | `R13` | `%blockIdx` | ✓ |
| `14` | `R14` | `%blockDim` | ✓ |
| `15` | `R15` | `%threadIdx` | ✓ |

## Encoding classes

| Type | Layout (`instr[15:0]`) |
|------|------------------------|
| `B` | `[15:12]=opcode | [11:9]=nzp | [8:0]=target` |
| `I` | `[15:12]=opcode | [11:8]=Rd | [7:0]=imm8` |
| `R` | `[15:12]=opcode | [11:8]=Rd | [7:4]=Rs | [3:0]=Rt` |
| `Z` | `[15:12]=opcode | [11:0]=0  (NOP / RET)` |

## Control signals

Every instruction emits a fixed bundle of control signals (mirrors `src/decoder.sv` outputs). Bits not listed default to zero. The C++ reference simulator decodes the same bundle from the auto-generated `sim/cppref/include/opengpu/isa_table.hpp`.

| Signal | Width |
|--------|:-----:|
| `reg_write_enable` | 1 |
| `mem_read_enable` | 1 |
| `mem_write_enable` | 1 |
| `nzp_write_enable` | 1 |
| `reg_input_mux` | 2 |
| `alu_arithmetic_mux` | 2 |
| `alu_output_mux` | 1 |
| `pc_mux` | 1 |
| `ret` | 1 |

## Instructions

### `NOP` — opcode `0x0` (Z-type)

- **Syntax:** `NOP`
- **Semantics:** no-op
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=0`, `reg_write_enable=0`, `ret=0`

### `BRnzp` — opcode `0x1` (B-type)

- **Syntax:** `BRnzp <nzp3>, <imm9>`
- **Semantics:** if (NZP & nzp_mask) PC <- imm9
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=1`, `reg_input_mux=0`, `reg_write_enable=0`, `ret=0`

### `CMP` — opcode `0x2` (R-type)

- **Syntax:** `CMP Rs, Rt`
- **Semantics:** NZP <- {Rs<Rt, Rs==Rt, Rs>Rt}
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=1`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=1`, `pc_mux=0`, `reg_input_mux=0`, `reg_write_enable=0`, `ret=0`

### `ADD` — opcode `0x3` (R-type)

- **Syntax:** `ADD Rd, Rs, Rt`
- **Semantics:** Rd <- Rs + Rt   (mod 2^8)
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=0`, `reg_write_enable=1`, `ret=0`

### `SUB` — opcode `0x4` (R-type)

- **Syntax:** `SUB Rd, Rs, Rt`
- **Semantics:** Rd <- Rs - Rt   (mod 2^8)
- **Control:** `alu_arithmetic_mux=1`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=0`, `reg_write_enable=1`, `ret=0`

### `MUL` — opcode `0x5` (R-type)

- **Syntax:** `MUL Rd, Rs, Rt`
- **Semantics:** Rd <- (Rs * Rt) & 0xFF
- **Control:** `alu_arithmetic_mux=2`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=0`, `reg_write_enable=1`, `ret=0`

### `DIV` — opcode `0x6` (R-type)

- **Syntax:** `DIV Rd, Rs, Rt`
- **Semantics:** Rd <- (Rt == 0) ? 0 : (Rs / Rt)
- **Control:** `alu_arithmetic_mux=3`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=0`, `reg_write_enable=1`, `ret=0`

### `LDR` — opcode `0x7` (R-type)

- **Syntax:** `LDR Rd, Rs`
- **Semantics:** Rd <- mem[Rs]
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=0`, `mem_read_enable=1`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=1`, `reg_write_enable=1`, `ret=0`

### `STR` — opcode `0x8` (R-type)

- **Syntax:** `STR Rs, Rt`
- **Semantics:** mem[Rs] <- Rt
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=1`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=0`, `reg_write_enable=0`, `ret=0`

### `CONST` — opcode `0x9` (I-type)

- **Syntax:** `CONST Rd, #imm8`
- **Semantics:** Rd <- imm8
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=2`, `reg_write_enable=1`, `ret=0`

### `ATOMICADD` — opcode `0xA` (R-type)

- **Syntax:** `ATOMICADD Rd, Rs, Rt`
- **Semantics:** old = mem[Rs]; mem[Rs] <- (old + Rt) & 0xFF; Rd <- old
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=0`, `mem_read_enable=1`, `mem_write_enable=1`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=1`, `reg_write_enable=1`, `ret=0`

### `RET` — opcode `0xF` (Z-type)

- **Syntax:** `RET`
- **Semantics:** thread halts (decoded_ret asserted)
- **Control:** `alu_arithmetic_mux=0`, `alu_output_mux=0`, `mem_read_enable=0`, `mem_write_enable=0`, `nzp_write_enable=0`, `pc_mux=0`, `reg_input_mux=0`, `reg_write_enable=0`, `ret=1`

