import cocotb
from cocotb.triggers import RisingEdge
from .helpers.setup import setup
from .helpers.memory import Memory
from .helpers.format import format_cycle
from .helpers.logger import logger

# Warp-scheduling (multi-warp SIMT) end-to-end test.
#
# Built by `make test_warp_scheduling_e2e`, which configures the GPU with
# THREADS_PER_WARP = 2 so each 4-thread block runs as 2 INDEPENDENT warps of
# 2 lanes, each with its own fetcher/icache/decoder/scheduler. This is the
# defining feature of real GPU cores: warps make independent forward
# progress, so one warp's stalls and branch paths do not serialise another's.
#
# The kernel is built to showcase exactly that. Threads take one of two
# WARP-ALIGNED divergent paths (threadIdx < 2 -> path A, else path B), and
# each path is a 6-iteration loop of slow memory loads:
#
#   * Single-warp (lockstep) core: min-PC reconvergence must execute path A
#     and path B SERIALLY for the whole block (~2x path time).
#   * Multi-warp core: warp 0 runs only path A while warp 1 concurrently
#     runs only path B (~1x path time + contention) - true warp scheduling.
#
# The data memory serves each access only after LATENCY cycles to make the
# per-warp memory stalls realistic. The test asserts:
#
#   1. The functional result is correct in either configuration.
#   2. Every warp retired instructions independently.
#   3. (Multi-warp builds) true overlap was observed: cycles where one warp
#      of a core sat in WAIT (memory) while its sibling warp made forward
#      progress. A lockstep single-warp core can never do this.
#
# Measured on this kernel (8 threads, LATENCY=8, cross-warp BAR at the join):
#   1 warp/core (lockstep):  868 cycles, overlap = 0   (paths serialise)
#   2 warps/core:            647 cycles, overlap = 310 (paths run concurrently)
LATENCY = 8

# Core FSM states (mirrors scheduler.sv)
WAIT_STATE = 0b100
BUSY_STATES = {0b001, 0b010, 0b011, 0b101, 0b110}  # FETCH/DECODE/REQUEST/EXECUTE/UPDATE


class DelayedMemory(Memory):
    """Memory model that serves each request only after `latency` cycles.

    The RTL holds valid high until ready, so a per-channel countdown that
    starts when valid is observed models a fixed-latency memory correctly.
    """

    def __init__(self, dut, addr_bits, data_bits, channels, name, latency=LATENCY):
        super().__init__(dut, addr_bits, data_bits, channels, name)
        self.latency = latency
        self._read_timers = [0] * channels
        self._write_timers = [0] * channels

    def run(self):
        # --- reads (delayed) ---
        valid_str = str(self.mem_read_valid.value)
        mem_read_valid = [int(valid_str[i], 2) for i in range(len(valid_str))]
        addr_str = str(self.mem_read_address.value)
        mem_read_address = [
            int(addr_str[i:i + self.addr_bits], 2)
            for i in range(0, len(addr_str), self.addr_bits)
        ]
        mem_read_ready = [0] * self.channels
        mem_read_data = [0] * self.channels

        for i in range(self.channels):
            if mem_read_valid[i] == 1:
                if self._read_timers[i] < self.latency:
                    self._read_timers[i] += 1
                else:
                    mem_read_data[i] = self.memory[mem_read_address[i]]
                    mem_read_ready[i] = 1
                    self._read_timers[i] = 0
            else:
                self._read_timers[i] = 0

        self.mem_read_data.value = int(
            ''.join(format(d, '0' + str(self.data_bits) + 'b') for d in mem_read_data), 2
        )
        self.mem_read_ready.value = int(
            ''.join(format(r, '01b') for r in mem_read_ready), 2
        )

        # --- writes (delayed) ---
        if self.name != "program":
            wvalid_str = str(self.mem_write_valid.value)
            mem_write_valid = [int(wvalid_str[i], 2) for i in range(len(wvalid_str))]
            waddr_str = str(self.mem_write_address.value)
            mem_write_address = [
                int(waddr_str[i:i + self.addr_bits], 2)
                for i in range(0, len(waddr_str), self.addr_bits)
            ]
            wdata_str = str(self.mem_write_data.value)
            mem_write_data = [
                int(wdata_str[i:i + self.data_bits], 2)
                for i in range(0, len(wdata_str), self.data_bits)
            ]
            mem_write_ready = [0] * self.channels

            for i in range(self.channels):
                if mem_write_valid[i] == 1:
                    if self._write_timers[i] < self.latency:
                        self._write_timers[i] += 1
                    else:
                        self.memory[mem_write_address[i]] = mem_write_data[i]
                        mem_write_ready[i] = 1
                        self._write_timers[i] = 0
                else:
                    self._write_timers[i] = 0

            self.mem_write_ready.value = int(
                ''.join(format(r, '01b') for r in mem_write_ready), 2
            )


@cocotb.test()
async def test_warp_scheduling(dut):
    # Program memory keeps the standard combinational model (fetch latency is
    # already exercised by the icache/prefetch tests); data memory is slow.
    program_memory = Memory(dut=dut, addr_bits=8, data_bits=16, channels=1, name="program")
    program = [
        0b0101000011011110,  # 0  MUL   R0, %blockIdx, %blockDim
        0b0011000000001111,  # 1  ADD   R0, R0, %threadIdx    ; i = global index
        0b1001000100000010,  # 2  CONST R1, #2
        0b0010000011110001,  # 3  CMP   %threadIdx, R1
        0b0001100000010011,  # 4  BRn   19                    ; tid<2 -> PATH A
        # PATH B (threads 2,3 of each block): 6 slow loads, then +200
        0b1001001000000110,  # 5  CONST R2, #6                ; k = 6
        0b1001001100000000,  # 6  CONST R3, #0                ; acc = 0
        0b1001010100000001,  # 7  CONST R5, #1
        0b1001011000000000,  # 8  CONST R6, #0
        0b0111010000000000,  # 9  LDR   R4, R0                ; LOOP B: slow load
        0b0011001100110100,  # 10 ADD   R3, R3, R4
        0b0100001000100101,  # 11 SUB   R2, R2, R5            ; k--
        0b0010000000100110,  # 12 CMP   R2, R6
        0b0001001000001001,  # 13 BRp   9                     ; while k > 0
        0b1001100011001000,  # 14 CONST R8, #200
        0b0011001100111000,  # 15 ADD   R3, R3, R8
        0b0001111000011111,  # 16 BRnzp 31                    ; join
        0b0000000000000000,  # 17 NOP
        0b0000000000000000,  # 18 NOP
        # PATH A (threads 0,1 of each block): 6 slow loads, then +100
        0b1001001000000110,  # 19 CONST R2, #6
        0b1001001100000000,  # 20 CONST R3, #0
        0b1001010100000001,  # 21 CONST R5, #1
        0b1001011000000000,  # 22 CONST R6, #0
        0b0111010000000000,  # 23 LDR   R4, R0                ; LOOP A: slow load
        0b0011001100110100,  # 24 ADD   R3, R3, R4
        0b0100001000100101,  # 25 SUB   R2, R2, R5
        0b0010000000100110,  # 26 CMP   R2, R6
        0b0001001000010111,  # 27 BRp   23
        0b1001100001100100,  # 28 CONST R8, #100
        0b0011001100111000,  # 29 ADD   R3, R3, R8
        0b0001111000011111,  # 30 BRnzp 31                    ; join
        # JOIN: block-wide barrier ACROSS warps, then store and retire.
        # In the multi-warp build the two warps arrive at different times;
        # the core-level coordinator parks the early warp and releases both
        # together (a deadlock here would hang the test - see cycle guard).
        0b1100000000000000,  # 31 BAR
        0b1001011100010000,  # 32 CONST R7, #16               ; baseC
        0b0011011101110000,  # 33 ADD   R7, R7, R0
        0b1000000001110011,  # 34 STR   R7, R3                ; C[i] = acc (slow)
        0b1111000000000000,  # 35 RET
    ]

    data_memory = DelayedMemory(
        dut=dut, addr_bits=8, data_bits=8, channels=4, name="data", latency=LATENCY
    )
    data = [5, 5, 5, 5, 5, 5, 5, 5]  # every slow load returns 5

    threads = 8  # 2 blocks x (2 warps x 2 lanes)

    await setup(
        dut=dut,
        program_memory=program_memory,
        program=program,
        data_memory=data_memory,
        data=data,
        threads=threads,
    )

    # Multi-warp build (via `make test_warp_scheduling_e2e`): 2 warps/core.
    # Single-warp default build (via `MODULE=test.test_warp_scheduling_e2e
    # make test_matadd`): serves as the lockstep baseline for comparison.
    num_warps = len(list(dut.cores[0].core_instance.warps))

    overlap_cycles = 0
    cycles = 0
    while dut.done.value != 1:
        # Deadlock guard: a broken cross-warp barrier would hang the sim.
        assert cycles < 20000, "kernel did not finish (cross-warp barrier deadlock?)"

        data_memory.run()
        program_memory.run()

        await cocotb.triggers.ReadOnly()
        format_cycle(dut, cycles)

        # Latency-hiding evidence: within a core, one warp waits on memory
        # while the sibling warp makes forward progress. With the scoreboard,
        # "waiting on memory" is either the synchronous WAIT state (atomics/
        # shared) or a hazard-stall in REQUEST while a posted LDR/STR is in
        # flight (plain loads/stores no longer sit in WAIT - the warp keeps
        # executing until a dependent instruction actually blocks).
        for core in dut.cores:
            blocked = []
            progressing = []
            for w in core.core_instance.warps:
                s = int(w.core_state.value)
                stalled = (
                    int(w.scheduler_instance.posted_valid.value) == 1
                    and int(w.scheduler_instance.issue_stall.value) == 1
                )
                is_blocked = (s == WAIT_STATE) or stalled
                blocked.append(is_blocked)
                progressing.append(s in BUSY_STATES and not is_blocked)
            if any(blocked) and any(progressing):
                overlap_cycles += 1

        await RisingEdge(dut.clk)
        cycles += 1

    # Let the registered per-core and top-level aggregations latch.
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    # 1. Functional correctness under multi-warp execution + slow memory.
    #    Path A threads: 6*5 + 100 = 130; path B threads: 6*5 + 200 = 230.
    for i in range(threads):
        expected = 130 if (i % 4) < 2 else 230
        result = data_memory.memory[16 + i]
        assert result == expected, (
            f"Result mismatch at index {i}: expected {expected}, got {result}"
        )

    # 2. Every warp retired instructions independently, and the cross-warp
    #    BAR was exercised (stall count is logged; skewed arrival parks the
    #    early warp until the coordinator releases the block).
    barrier_stalls = 0
    for core in dut.cores:
        for w in core.core_instance.warps:
            retired = int(w.scheduler_instance.perf_instr_count.value)
            assert retired > 0, "every warp must retire instructions"
            barrier_stalls += int(w.scheduler_instance.perf_barrier_count.value)

    logger.info(
        f"warp scheduling: warps_per_core={num_warps} cycles={cycles} "
        f"overlap_cycles={overlap_cycles} barrier_stalls={barrier_stalls} "
        f"(one warp in WAIT while sibling progressed)"
    )

    # 3. True latency hiding was observed (multi-warp builds only). With
    #    LATENCY-cycle memory and independent per-warp FSMs, overlap is
    #    guaranteed; a lockstep single-warp core always scores 0 here.
    if num_warps > 1:
        assert overlap_cycles > 0, (
            "expected at least one cycle where a warp was blocked on memory "
            "while its sibling warp executed - warp scheduling is not hiding "
            "latency"
        )
    else:
        assert overlap_cycles == 0, (
            "a single-warp core cannot overlap a memory-blocked warp with a "
            "progressing one"
        )
