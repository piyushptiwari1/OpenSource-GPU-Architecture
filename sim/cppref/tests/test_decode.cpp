// Decode-table sanity tests. Mirrors the localparams in src/decoder.sv;
// any divergence between this test and the RTL decoder is a real bug.

#include <catch2/catch_test_macros.hpp>

#include "opengpu/isa_table.hpp"

using opengpu::isa::decode;
using opengpu::isa::Opcode;

TEST_CASE("opcode field is the high nibble", "[decode]") {
    REQUIRE(decode(0x3000).op == Opcode::ADD);
    REQUIRE(decode(0x4000).op == Opcode::SUB);
    REQUIRE(decode(0x5000).op == Opcode::MUL);
    REQUIRE(decode(0x6000).op == Opcode::DIV);
    REQUIRE(decode(0x7000).op == Opcode::LDR);
    REQUIRE(decode(0x8000).op == Opcode::STR);
    REQUIRE(decode(0x9000).op == Opcode::CONST);
    REQUIRE(decode(0xF000).op == Opcode::RET);
}

TEST_CASE("R-type field layout matches decoder.sv", "[decode]") {
    // ADD R5, R10, R3 -> 0x3 5 A 3
    auto d = decode(0x35A3);
    REQUIRE(d.op == Opcode::ADD);
    REQUIRE(d.rd == 0x5);
    REQUIRE(d.rs == 0xA);
    REQUIRE(d.rt == 0x3);
    REQUIRE(d.reg_write_enable == 1);
    REQUIRE(d.alu_arithmetic_mux == 0);
}

TEST_CASE("I-type CONST decodes immediate", "[decode]") {
    // CONST R7, #0x5A -> 0x9 7 5A
    auto d = decode(0x975A);
    REQUIRE(d.op == Opcode::CONST);
    REQUIRE(d.rd == 0x7);
    REQUIRE(d.imm8 == 0x5A);
    REQUIRE(d.reg_input_mux == 2);
}

TEST_CASE("B-type BRnzp decodes nzp + target", "[decode]") {
    // BRnzp 0b101, target=0x12 -> 0x1 [101] [0_0001_0010] -> 0x1A12
    auto d = decode(0x1A12);
    REQUIRE(d.op == Opcode::BRnzp);
    REQUIRE(d.nzp == 0b101);
    REQUIRE((d.imm9 & 0xFF) == 0x12);
    REQUIRE(d.pc_mux == 1);
}

TEST_CASE("RET sets ret control bit", "[decode]") {
    auto d = decode(0xF000);
    REQUIRE(d.op == Opcode::RET);
    REQUIRE(d.ret == 1);
}

TEST_CASE("unknown opcode is benign", "[decode]") {
    // 0xC is currently unassigned (0xA = ATOMICADD, 0xB = ATOMICCAS).
    auto d = decode(0xC000);
    REQUIRE(opengpu::isa::lookup(0xC) == nullptr);
    REQUIRE(d.reg_write_enable == 0);
}

TEST_CASE("ATOMICADD decodes as R-type with read+write", "[decode]") {
    // ATOMICADD R3, R4, R5  =>  0xA @ 3 @ 4 @ 5
    auto d = decode(0xA345);
    REQUIRE(d.op == Opcode::ATOMICADD);
    REQUIRE(d.rd == 3);
    REQUIRE(d.rs == 4);
    REQUIRE(d.rt == 5);
    REQUIRE(d.reg_write_enable == 1);
    REQUIRE(d.mem_read_enable  == 1);
    REQUIRE(d.mem_write_enable == 1);
}

TEST_CASE("ATOMICCAS decodes as R-type with read+write", "[decode]") {
    // ATOMICCAS R6, R7, R8  =>  0xB @ 6 @ 7 @ 8
    auto d = decode(0xB678);
    REQUIRE(d.op == Opcode::ATOMICCAS);
    REQUIRE(d.rd == 6);
    REQUIRE(d.rs == 7);
    REQUIRE(d.rt == 8);
    REQUIRE(d.reg_write_enable == 1);
    REQUIRE(d.mem_read_enable  == 1);
    REQUIRE(d.mem_write_enable == 1);
}
