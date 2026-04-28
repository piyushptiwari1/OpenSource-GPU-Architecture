// Trace sink for the OpenGPU C++ reference simulator.
//
// One JSON line per retired instruction. Schema (stable, consumed by
// tools/difftest/cocotb_diff.py):
//
// {
//   "tick"  : <uint64>,           // monotonic across the run
//   "tid"   : <uint8>,            // thread id within the block
//   "pc"    : <uint16>,           // PC of the retired instruction
//   "instr" : <uint16>,           // raw 16-bit instruction word
//   "op"    : "<mnemonic>",
//   "rd"    : <uint8>,            // 0xFF if not written
//   "rd_val": <uint8>,            // ignored if rd == 0xFF
//   "mem_w" : { "addr": u8, "val": u8 } | null,
//   "nzp"   : <uint8>,
//   "done"  : <bool>
// }
//
// Memory loads do not need a record because the host-visible state
// after the load is captured by the rd write.

#pragma once

#include <cstdint>
#include <fstream>
#include <optional>
#include <string>
#include <string_view>

namespace opengpu::ref {

struct TraceRecord {
    std::uint64_t tick;
    std::uint8_t  tid;
    std::uint16_t pc;
    std::uint16_t instr;
    std::string_view op;
    std::uint8_t  rd;       // 0xFF == none
    std::uint8_t  rd_val;
    std::optional<std::pair<std::uint8_t, std::uint8_t>> mem_w;
    std::uint8_t  nzp;
    bool          done;
};

class TraceSink {
public:
    explicit TraceSink(const std::string& path);
    ~TraceSink();

    TraceSink(const TraceSink&)            = delete;
    TraceSink& operator=(const TraceSink&) = delete;

    void emit(const TraceRecord& r);

private:
    std::ofstream out_;
};

}  // namespace opengpu::ref
