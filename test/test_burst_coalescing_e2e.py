import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Address-range (burst) coalescing end-to-end test.
#
# A warp accessing NEIGHBOURING addresses (in[2i], in[2i+1] per thread - the
# classic strided pattern) used to cost one scattered external word read per
# lane. With the line-interleaved L2, the lane that misses pulls in the whole
# 4-word line as ONE sequential burst on its bank's channel, and the
# neighbours hit on-chip.
#
# External memory here is an OPEN-ROW model (like real DRAM): an access that
# continues sequentially from the previous address on the same channel is
# fast (1 cycle); any other access pays the full row-activation latency
# (6 cycles). Scattered word reads pay the row penalty every time; the L2's
# line bursts pay it once per line then stream.
#
# Asserted architectural invariants:
#   1. Results are correct: out[i] = 2 * (in[2i] + in[2i+1]).
#   2. hits + misses == 32 (every LDR passes the L2 exactly once).
#   3. misses == 4: one per touched 4-word line - lanes sharing a line
#      serialise at its home bank and the second lane hits the fresh fill.
#   4. External read beats == misses * 4 (only full-line bursts on the pins:
#      32 scattered loads became 4 bursts).
#   5. At least 3 of every burst's 4 beats are address-sequential on their
#      channel - the traffic shape real DRAM serves cheaply.
#   6. Write-through: external write beats == 8 stores.
#
# Kernel (PC : instruction):
#   0  MUL   R0, %blockIdx, %blockDim
#   1  ADD   R0, R0, %threadIdx        ; i = global thread index
#   2  ADD   R1, R0, R0                ; base = 2i
#   3  CONST R2, #1
#   4  CONST R3, #2                    ; loop bound
#   5  CONST R4, #0                    ; acc = 0
#   6  CONST R5, #0                    ; k = 0
#   7  LDR   R6, R1                    ; LOOP: load in[2i]
#   8  ADD   R7, R1, R2
#   9  LDR   R7, R7                    ; load in[2i+1]
#   10 ADD   R4, R4, R6
#   11 ADD   R4, R4, R7                ; acc += in[2i] + in[2i+1]
#   12 ADD   R5, R5, R2                ; k++
#   13 CMP   R5, R3
#   14 BRn   7                         ; while k < 2
#   15 CONST R8, #16
#   16 ADD   R8, R8, R0                ; &out[i]
#   17 STR   R8, R4
#   18 RET

ROW_LATENCY = 6   # cycles for a non-sequential ("row miss") access
OPEN_LATENCY = 1  # cycles for a sequential ("open row") access


class OpenRowMemory(Memory):
    """DRAM-like model: sequential next-address reads on a channel are fast,
    everything else pays the row-activation latency."""

    def __init__(self, dut, addr_bits, data_bits, channels, name):
        super().__init__(dut, addr_bits, data_bits, channels, name)
        self._read_timers = [0] * channels
        self._last_read_addr = [None] * channels
        self._write_timers = [0] * channels
        # Beat statistics for the assertions.
        self.read_beats = 0
        self.sequential_read_beats = 0
        self.write_beats = 0

    def run(self):
        valid_str = str(self.mem_read_valid.value)
        read_valid = [int(valid_str[i], 2) for i in range(len(valid_str))]
        addr_str = str(self.mem_read_address.value)
        read_addr = [
            int(addr_str[i:i + self.addr_bits], 2)
            for i in range(0, len(addr_str), self.addr_bits)
        ]
        read_ready = [0] * self.channels
        read_data = [0] * self.channels

        for i in range(self.channels):
            if read_valid[i] == 1:
                sequential = (
                    self._last_read_addr[i] is not None
                    and read_addr[i] == self._last_read_addr[i] + 1
                )
                needed = OPEN_LATENCY if sequential else ROW_LATENCY
                if self._read_timers[i] < needed:
                    self._read_timers[i] += 1
                else:
                    read_data[i] = self.memory[read_addr[i]]
                    read_ready[i] = 1
                    self._read_timers[i] = 0
                    self.read_beats += 1
                    if sequential:
                        self.sequential_read_beats += 1
                    self._last_read_addr[i] = read_addr[i]
            else:
                self._read_timers[i] = 0

        self.mem_read_data.value = int(
            ''.join(format(d, '0' + str(self.data_bits) + 'b') for d in read_data), 2
        )
        self.mem_read_ready.value = int(
            ''.join(format(r, '01b') for r in read_ready), 2
        )

        if self.name != "program":
            wvalid_str = str(self.mem_write_valid.value)
            write_valid = [int(wvalid_str[i], 2) for i in range(len(wvalid_str))]
            waddr_str = str(self.mem_write_address.value)
            write_addr = [
                int(waddr_str[i:i + self.addr_bits], 2)
                for i in range(0, len(waddr_str), self.addr_bits)
            ]
            wdata_str = str(self.mem_write_data.value)
            write_data = [
                int(wdata_str[i:i + self.data_bits], 2)
                for i in range(0, len(wdata_str), self.data_bits)
            ]
            write_ready = [0] * self.channels

            for i in range(self.channels):
                if write_valid[i] == 1:
                    if self._write_timers[i] < ROW_LATENCY:
                        self._write_timers[i] += 1
                    else:
                        self.memory[write_addr[i]] = write_data[i]
                        write_ready[i] = 1
                        self._write_timers[i] = 0
                        self.write_beats += 1
                else:
                    self._write_timers[i] = 0

            self.mem_write_ready.value = int(
                ''.join(format(r, '01b') for r in write_ready), 2
            )


@cocotb.test()
async def test_burst_coalescing(dut):
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
        0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx
        0b0011000100000000,  # 2  ADD   R1, R0, R0
        0b1001001000000001,  # 3  CONST R2, #1
        0b1001001100000010,  # 4  CONST R3, #2
        0b1001010000000000,  # 5  CONST R4, #0
        0b1001010100000000,  # 6  CONST R5, #0
        0b0111011000010000,  # 7  LDR   R6, R1
        0b0011011100010010,  # 8  ADD   R7, R1, R2
        0b0111011101110000,  # 9  LDR   R7, R7
        0b0011010001000110,  # 10 ADD   R4, R4, R6
        0b0011010001000111,  # 11 ADD   R4, R4, R7
        0b0011010101010010,  # 12 ADD   R5, R5, R2
        0b0010000001010011,  # 13 CMP   R5, R3
        0b0001100000000111,  # 14 BRn   7
        0b1001100000010000,  # 15 CONST R8, #16
        0b0011100010000000,  # 16 ADD   R8, R8, R0
        0b1000000010000100,  # 17 STR   R8, R4
        0b1111000000000000,  # 18 RET
    ]

    data_memory = OpenRowMemory(dut=dut, addr_bits=8, data_bits=8, channels=4, name="data")
    in_data = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3]  # in[0..15]
    data = in_data + [0] * 16  # out region at 16..23

    threads = 8
    loop_count = 2
    total_loads = threads * 2 * loop_count  # 32
    total_stores = threads                  # 8
    words_per_line = 4
    touched_lines = 4                       # in[0..15] = lines 0..3

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    cycles = 0
    while dut.done.value != 1:
        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        await RisingEdge(dut.clk)
        cycles += 1
        assert cycles < 20000, "kernel did not finish"

    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # 1. Correctness.
    for i in range(threads):
        expected = loop_count * (in_data[2 * i] + in_data[2 * i + 1])
        result = data_memory.memory[16 + i]
        assert result == expected, f"out[{i}]: expected {expected}, got {result}"

    l2_hits = int(dut.perf_l2_hit_count.value)
    l2_misses = int(dut.perf_l2_miss_count.value)

    logger.info(
        f"burst: hits={l2_hits} misses={l2_misses} "
        f"ext_read_beats={data_memory.read_beats} "
        f"sequential_beats={data_memory.sequential_read_beats} "
        f"ext_write_beats={data_memory.write_beats} cycles={cycles}"
    )

    # 2. Every load passes the L2 exactly once.
    assert l2_hits + l2_misses == total_loads, (
        f"L2 saw {l2_hits}+{l2_misses} reads, expected {total_loads}"
    )

    # 3. Exactly one miss per touched line (neighbours hit the fresh fill).
    assert l2_misses == touched_lines, (
        f"expected {touched_lines} line misses, got {l2_misses}"
    )

    # 4. Only full-line bursts on the external pins.
    assert data_memory.read_beats == l2_misses * words_per_line, (
        f"external memory saw {data_memory.read_beats} read beats, expected "
        f"{l2_misses} bursts x {words_per_line} beats"
    )

    # 5. Bursts are address-sequential (open-row friendly): all beats after
    #    each burst's opener continue at the previous address + 1.
    assert data_memory.sequential_read_beats >= l2_misses * (words_per_line - 1), (
        f"only {data_memory.sequential_read_beats} sequential beats for "
        f"{l2_misses} bursts - line fills should stream sequential addresses"
    )

    # 6. Write-through: every store reaches external memory.
    assert data_memory.write_beats == total_stores, (
        f"external memory saw {data_memory.write_beats} writes, expected {total_stores}"
    )
