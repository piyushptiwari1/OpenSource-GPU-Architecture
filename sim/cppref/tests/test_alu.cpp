// Single-thread ALU semantics (mirrors src/alu.sv at the architectural
// level; ignores per-cycle latency).

#include <catch2/catch_test_macros.hpp>

#include "opengpu/core.hpp"
#include "opengpu/memory.hpp"

using namespace opengpu::ref;

namespace {

[[nodiscard]] std::uint16_t encode_const(std::uint8_t rd, std::uint8_t imm) {
    return static_cast<std::uint16_t>((0x9u << 12) | ((rd & 0xFu) << 8) | imm);
}
[[nodiscard]] std::uint16_t encode_r(std::uint8_t op, std::uint8_t rd,
                                     std::uint8_t rs, std::uint8_t rt) {
    return static_cast<std::uint16_t>(
        (op << 12) | ((rd & 0xFu) << 8) | ((rs & 0xFu) << 4) | (rt & 0xFu));
}
[[nodiscard]] std::uint16_t encode_ret() { return 0xF000; }

ThreadState run_program(std::span<const std::uint16_t> program,
                        std::uint8_t threads = 1) {
    Memory mem(256);
    Core core({.block_idx = 0, .block_dim = threads, .max_steps = 1000U},
              program, mem);
    core.run(nullptr);
    return core.threads().front();
}

}  // namespace

TEST_CASE("ADD wraps at 8 bits", "[alu]") {
    std::vector<std::uint16_t> prog = {
        encode_const(1, 0xFF),
        encode_const(2, 0x02),
        encode_r(0x3, 3, 1, 2),  // ADD R3, R1, R2
        encode_ret(),
    };
    auto th = run_program(prog);
    REQUIRE(th.regs[3] == static_cast<std::uint8_t>(0x101));  // 0x01
    REQUIRE(th.done);
}

TEST_CASE("DIV by zero returns 0 per ISA spec", "[alu]") {
    std::vector<std::uint16_t> prog = {
        encode_const(1, 50),
        encode_const(2, 0),
        encode_r(0x6, 3, 1, 2),  // DIV R3, R1, R2
        encode_ret(),
    };
    auto th = run_program(prog);
    REQUIRE(th.regs[3] == 0);
}

TEST_CASE("CMP populates NZP flags { n, z, p }", "[alu]") {
    auto run_cmp = [](std::uint8_t a, std::uint8_t b) {
        std::vector<std::uint16_t> prog = {
            encode_const(1, a),
            encode_const(2, b),
            encode_r(0x2, 0, 1, 2),  // CMP R1, R2
            encode_ret(),
        };
        return run_program(prog).nzp;
    };
    REQUIRE(run_cmp(1, 2) == 0b100);  // n
    REQUIRE(run_cmp(2, 2) == 0b010);  // z
    REQUIRE(run_cmp(3, 2) == 0b001);  // p
}

TEST_CASE("Per-thread threadIdx visible via R15", "[alu]") {
    std::vector<std::uint16_t> prog = {
        encode_r(0x3, 3, 15, 15),  // ADD R3, R15, R15  -> 2*tid
        encode_ret(),
    };
    Memory mem(256);
    Core core({.block_idx = 0, .block_dim = 4, .max_steps = 1000U},
              prog, mem);
    core.run(nullptr);
    for (std::size_t t = 0; t < 4; ++t) {
        REQUIRE(core.threads()[t].regs[3] == static_cast<std::uint8_t>(2 * t));
    }
}
