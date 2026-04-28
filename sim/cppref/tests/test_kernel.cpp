// End-to-end kernel test: vector-add of length 8.
// Identical inputs and expected outputs to the cocotb matadd test; this
// makes the refsim a usable golden during DiffTest bring-up.

#include <catch2/catch_test_macros.hpp>

#include "opengpu/core.hpp"
#include "opengpu/memory.hpp"

using namespace opengpu::ref;

namespace {
constexpr std::uint16_t I(std::uint16_t op, std::uint16_t rd,
                          std::uint16_t rs, std::uint16_t rt) {
    return static_cast<std::uint16_t>((op << 12) | (rd << 8) | (rs << 4) | rt);
}
constexpr std::uint16_t C(std::uint16_t rd, std::uint16_t imm) {
    return static_cast<std::uint16_t>((0x9 << 12) | (rd << 8) | imm);
}
}  // namespace

TEST_CASE("matadd-8 reproduces cocotb golden", "[kernel]") {
    // Layout (matches test/test_matadd.py):
    //   data[ 0..7] = A (1..8)
    //   data[ 8..15] = B (1..8)
    //   data[16..23] = C = A + B (computed)
    std::vector<std::uint16_t> prog = {
        C(0, 0),                  // R0 <- 0    (base of A)
        C(1, 8),                  // R1 <- 8    (base of B)
        C(2, 16),                 // R2 <- 16   (base of C)
        I(0x3, 3, 0, 15),         // R3 <- A_base + tid
        I(0x3, 4, 1, 15),         // R4 <- B_base + tid
        I(0x3, 5, 2, 15),         // R5 <- C_base + tid
        I(0x7, 6, 3, 0),          // R6 <- mem[R3]   (LDR)
        I(0x7, 7, 4, 0),          // R7 <- mem[R4]   (LDR)
        I(0x3, 8, 6, 7),          // R8 <- R6 + R7   (ADD)
        I(0x8, 0, 5, 8),          // mem[R5] <- R8   (STR)
        0xF000,                   // RET
    };

    Memory mem(64);
    for (int i = 0; i < 8; ++i) {
        mem.raw()[static_cast<std::size_t>(i)]     = static_cast<std::uint8_t>(i + 1);
        mem.raw()[static_cast<std::size_t>(i + 8)] = static_cast<std::uint8_t>(i + 1);
    }

    Core core({.block_idx = 0, .block_dim = 8, .max_steps = 1000U}, prog, mem);
    core.run(nullptr);

    for (int i = 0; i < 8; ++i) {
        REQUIRE(mem.raw()[static_cast<std::size_t>(i + 16)] ==
                static_cast<std::uint8_t>((i + 1) * 2));
    }
}
