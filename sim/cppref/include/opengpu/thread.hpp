// Per-thread architectural state in the OpenGPU C++ reference simulator.

#pragma once

#include <array>
#include <cstdint>

#include "isa_table.hpp"

namespace opengpu::ref {

struct ThreadState {
    static constexpr std::size_t kRegCount =
        static_cast<std::size_t>(opengpu::isa::kNumRegisters);

    std::uint16_t pc        = 0;
    std::uint8_t  nzp       = 0;          // 3-bit flag register
    bool          done      = false;
    bool          enabled   = true;       // false => masked off
    std::array<std::uint8_t, kRegCount> regs{};

    // Read-only system registers, set once at thread spawn.
    void set_block_context(std::uint8_t block_idx,
                           std::uint8_t block_dim,
                           std::uint8_t thread_idx) noexcept {
        regs[13] = block_idx;
        regs[14] = block_dim;
        regs[15] = thread_idx;
    }
};

}  // namespace opengpu::ref
