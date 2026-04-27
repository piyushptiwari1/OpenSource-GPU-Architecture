from typing import List
from .logger import logger

# This class is NOT a RAM macro inside the RTL; it is a *software* memory
# model that lives inside the cocotb testbench. Think of it as Python
# pretending to be a memory peripheral on the outside of the DUT, and
# interacting with the Verilog top through the read/write handshake signals
# the design exposes.
class Memory:
    # In Python, `def` defines a function. When written inside a class, it is
    # a method. `__init__` is the constructor, similar to "code that runs when
    # an object is created." `self` is "this object," the same idea as `this`
    # in many other languages.
    def __init__(self, dut, addr_bits, data_bits, channels, name):
        # Save the DUT handle that cocotb passed in; we'll use it later to
        # drive top-level signals through `self.dut`.
        self.dut = dut
        # Save the address width (e.g. 8 means an 8-bit address bus, addressing
        # 2**8 = 256 locations).
        self.addr_bits = addr_bits
        # Save the data width (e.g. 8 means each location stores 8 bits).
        self.data_bits = data_bits
        # `[0] * N` builds a list of length N with every element initialised
        # to 0; here it models a flat block of memory with `2**addr_bits`
        # locations.
        self.memory = [0] * (2**addr_bits)
        # `channels` is the number of parallel access lanes -- it matches the
        # number of memory consumers the RTL can serve in one cycle.
        self.channels = channels
        # `name` distinguishes program memory from data memory and is also
        # used to build the matching DUT signal names below.
        self.name = name

        # `getattr(obj, "attr")` looks up an attribute on `obj` by string name.
        # Combined with f-strings, it lets us splice `name` dynamically into
        # the signal name -- e.g. when `name == "data"` we end up grabbing
        # `dut.data_mem_read_valid`.
        # Read address bus: the DUT puts the address it wants to read here.
        self.mem_read_valid = getattr(dut, f"{name}_mem_read_valid")
        self.mem_read_address = getattr(dut, f"{name}_mem_read_address")
        # Read ready bus: this Python memory model drives it back to the DUT
        # to mean "I accepted this read."
        self.mem_read_ready = getattr(dut, f"{name}_mem_read_ready")
        # Read data bus: this Python memory model drives it back to the DUT
        # to mean "here is the value you read."
        self.mem_read_data = getattr(dut, f"{name}_mem_read_data")

        # Program memory is read-only in this design, so only data memory
        # needs the write-side handshake hooked up.
        if name != "program":
            # Write valid: DUT raises this to mean a lane is issuing a write.
            self.mem_write_valid = getattr(dut, f"{name}_mem_write_valid")
            # Write address: where the DUT wants the value stored.
            self.mem_write_address = getattr(dut, f"{name}_mem_write_address")
            # Write data: the value the DUT wants to store.
            self.mem_write_data = getattr(dut, f"{name}_mem_write_data")
            # Write ready: this Python memory model drives it back to the DUT
            # to mean "I accepted this write."
            self.mem_write_ready = getattr(dut, f"{name}_mem_write_ready")

    # `run()` advances the software memory by one simulation cycle of
    # combinational / handshake logic. The `cycle` argument is not strictly
    # required; it is just useful when printing per-cycle log lines.
    def run(self):
        # Convert the cocotb signal value into a Python string so we can slice
        # it bit-by-bit. For a multi-channel valid bus this might look like
        # the binary string "1010".
        # Then walk the string one bit at a time and decode each lane's
        # valid bit into an int.
        mem_read_valid = [
            # `int(s, 2)` parses a binary string into a decimal integer.
            int(str(self.mem_read_valid.value)[i:i+1], 2)
            # `range(start, stop, step)` produces an integer sequence. With
            # step = 1 we walk the string one bit at a time.
            for i in range(0, len(str(self.mem_read_valid.value)), 1)
        ]

        # The address bus is the concatenation of every lane's address, each
        # `addr_bits` wide, so the slice step here is `addr_bits`.
        mem_read_address = [
            # Python slice `s[a:b]` is a half-open interval [a, b).
            int(str(self.mem_read_address.value)[i:i+self.addr_bits], 2)
            for i in range(0, len(str(self.mem_read_address.value)), self.addr_bits)
        ]
        # Default: every lane reports "not ready"; the lanes that actually
        # requested a read will be set to 1 below.
        mem_read_ready = [0] * self.channels
        # Pre-allocate one return-data slot per lane.
        mem_read_data = [0] * self.channels

        # Per-channel handling, mirroring the "for each lane" loops in RTL.
        for i in range(self.channels):
            # If valid is 1 the DUT really did issue a read this cycle.
            if mem_read_valid[i] == 1:
                # Use the requested address as a list index to fetch from the
                # software memory.
                mem_read_data[i] = self.memory[mem_read_address[i]]
                # Tell the DUT the read has been served.
                mem_read_ready[i] = 1
            else:
                # Lane did not request anything -- explicitly drive ready=0.
                mem_read_ready[i] = 0

        # Pack each lane's integer back into a fixed-width binary string. The
        # width is not hard-coded; it is built dynamically with
        # `"0" + str(self.data_bits) + "b"`.
        # `"".join(list)` concatenates the per-lane strings into the full bus
        # string, and `int(s, 2)` converts it back into an integer that can
        # be assigned to `cocotb_signal.value`.
        self.mem_read_data.value = int(''.join(format(d, '0' + str(self.data_bits) + 'b') for d in mem_read_data), 2)
        self.mem_read_ready.value = int(''.join(format(r, '01b') for r in mem_read_ready), 2)

        if self.name != "program":
            mem_write_valid = [
                int(str(self.mem_write_valid.value)[i:i+1], 2)
                for i in range(0, len(str(self.mem_write_valid.value)), 1)
            ]
            mem_write_address = [
                int(str(self.mem_write_address.value)[i:i+self.addr_bits], 2)
                for i in range(0, len(str(self.mem_write_address.value)), self.addr_bits)
            ]
            mem_write_data = [
                int(str(self.mem_write_data.value)[i:i+self.data_bits], 2)
                for i in range(0, len(str(self.mem_write_data.value)), self.data_bits)
            ]
            mem_write_ready = [0] * self.channels

            for i in range(self.channels):
                if mem_write_valid[i] == 1:
                    self.memory[mem_write_address[i]] = mem_write_data[i]
                    mem_write_ready[i] = 1
                else:
                    mem_write_ready[i] = 0

            self.mem_write_ready.value = int(''.join(format(w, '01b') for w in mem_write_ready), 2)

    def write(self, address, data):
        if address < len(self.memory):
            self.memory[address] = data

    def load(self, rows: List[int]):
        for address, data in enumerate(rows):
            self.write(address, data)

    def display(self, rows, decimal=True):
        logger.info("\n")
        logger.info(f"{self.name.upper()} MEMORY")

        table_size = (8 * 2) + 3
        logger.info("+" + "-" * (table_size - 3) + "+")

        header = "| Addr | Data "
        logger.info(header + " " * (table_size - len(header) - 1) + "|")

        logger.info("+" + "-" * (table_size - 3) + "+")
        for i, data in enumerate(self.memory):
            if i < rows:
                if decimal:
                    row = f"| {i:<4} | {data:<4}"
                    logger.info(row + " " * (table_size - len(row) - 1) + "|")
                else:
                    data_bin = format(data, f'0{16}b')
                    row = f"| {i:<4} | {data_bin} |"
                    logger.info(row + " " * (table_size - len(row) - 1) + "|")
