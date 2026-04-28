// One block executor: an array of threads sharing a program and memory.
// Mirrors the per-core dispatch loop in src/core.sv at the architectural
// level (no pipeline, no stalls -- one decoded instruction per step).

#pragma once

#include <cstdint>
#include <span>
#include <vector>

#include "memory.hpp"
#include "thread.hpp"
#include "trace.hpp"

namespace opengpu::ref {

struct CoreConfig {
    std::uint8_t  block_idx  = 0;
    std::uint8_t  block_dim  = 1;       // number of threads in this block
    std::uint32_t max_steps  = 100000;  // safety bound (per-thread step cap)
};

class Core {
public:
    Core(CoreConfig cfg, std::span<const std::uint16_t> program, Memory& memory);

    // Run all threads to completion (RET) or until max_steps is exhausted.
    // Returns total retired instructions across the block.
    std::uint64_t run(TraceSink* trace = nullptr);

    [[nodiscard]] const std::vector<ThreadState>& threads() const noexcept { return threads_; }
    [[nodiscard]] const Memory& memory() const noexcept { return memory_; }

private:
    void step_thread(std::size_t tid, TraceSink* trace);

    CoreConfig                       cfg_;
    std::span<const std::uint16_t>   program_;
    Memory&                          memory_;
    std::vector<ThreadState>         threads_;
};

}  // namespace opengpu::ref
