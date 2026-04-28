# OpenGPU on Tiny Tapeout

## What it is

OpenGPU is a small SIMT GPU forked from
[adam-maj/tiny-gpu](https://github.com/adam-maj/tiny-gpu) (MIT). It
runs short kernels (≤ 16 instructions) over a configurable number of
threads (default 8) and exposes a deliberately tiny ISA so the whole
control + datapath fits on a Tiny Tapeout multi-tile area in sky130A.

The Tiny Tapeout submission uses a serial command/data wrapper so the
host can program instruction memory, write data memory, set the warp
size, and start/stop execution through the standard 24-pin TT
interface.

## How it works

The wrapper accepts a 4-bit command in `ui_in[7:4]` plus a payload
byte in `ui_in[3:0]` and the bidirectional `uio[7:0]` bus, and reports
status / readback bytes on `uo_out`. The supported commands are:

| Cmd | Name              | Payload                           |
|-----|-------------------|-----------------------------------|
| 0x0 | NOP               | (none)                            |
| 0x1 | WRITE_PROG        | addr (uio), opcode (ui_in[3:0])   |
| 0x2 | WRITE_DATA        | addr (uio), data (ui_in[3:0])     |
| 0x3 | READ_DATA         | addr (uio); result on uo_out      |
| 0x4 | SET_THREAD_COUNT  | thread_count (uio)                |
| 0x5 | START             | (none)                            |
| 0x6 | STATUS            | result on uo_out: {done, busy, …} |
| 0x7 | RESET_INTERNAL    | (none)                            |

Inside the wrapper, the GPU itself is unchanged: SIMT scheduler →
fetch → decode → dispatch (ALU/LSU) → register file. The data memory
is small enough to live on-die alongside the wrapper.

## How to test

After programming a kernel and data, pulse the `START` command and
poll `STATUS` until `done = 1`, then issue `READ_DATA` for each
output address. A reference cocotb test under `test/cocotb/`
exercises this protocol against the same wrapper used here.

## External hardware

None required. All I/O is via the TT board's pinout.

## Acknowledgements

- Original RTL: [adam-maj/tiny-gpu](https://github.com/adam-maj/tiny-gpu) (MIT)
- Tiny Tapeout: <https://tinytapeout.com>
- Sky130 PDK: <https://github.com/google/skywater-pdk>
