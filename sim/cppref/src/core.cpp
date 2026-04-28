#include "opengpu/core.hpp"

#include <algorithm>
#include <cstdint>
#include <stdexcept>

#include "opengpu/isa_table.hpp"

namespace opengpu::ref {

namespace {

[[nodiscard]] std::uint8_t alu_arith(std::uint8_t op, std::uint8_t rs, std::uint8_t rt) noexcept {
    switch (op) {
        case 0b00: return static_cast<std::uint8_t>(rs + rt);
        case 0b01: return static_cast<std::uint8_t>(rs - rt);
        case 0b10: return static_cast<std::uint8_t>(rs * rt);
        case 0b11:
            // See docs/isa/instructions.yaml: divide-by-zero -> 0.
            return rt == 0 ? std::uint8_t{0} : static_cast<std::uint8_t>(rs / rt);
        default: return 0;
    }
}

[[nodiscard]] std::uint8_t alu_cmp(std::uint8_t rs, std::uint8_t rt) noexcept {
    // Layout matches src/alu.sv: { n, z, p } = { rs<rt, rs==rt, rs>rt }.
    const std::uint8_t n = (rs <  rt) ? 1 : 0;
    const std::uint8_t z = (rs == rt) ? 1 : 0;
    const std::uint8_t p = (rs >  rt) ? 1 : 0;
    return static_cast<std::uint8_t>((n << 2) | (z << 1) | p);
}

}  // namespace

Core::Core(CoreConfig cfg, std::span<const std::uint16_t> program, Memory& memory)
    : cfg_(cfg), program_(program), memory_(memory) {
    if (cfg_.block_dim == 0) {
        throw std::invalid_argument("block_dim must be >= 1");
    }
    threads_.resize(cfg_.block_dim);
    for (std::uint8_t t = 0; t < cfg_.block_dim; ++t) {
        threads_[t].set_block_context(cfg_.block_idx, cfg_.block_dim, t);
    }
}

std::uint64_t Core::run(TraceSink* trace) {
    std::uint64_t retired = 0;
    for (std::uint32_t step = 0; step < cfg_.max_steps; ++step) {
        bool any_active = false;
        for (std::size_t tid = 0; tid < threads_.size(); ++tid) {
            if (threads_[tid].done) continue;
            any_active = true;
            step_thread(tid, trace);
            ++retired;
        }
        if (!any_active) break;
    }
    return retired;
}

void Core::step_thread(std::size_t tid, TraceSink* trace) {
    auto& th = threads_[tid];
    if (th.pc >= program_.size()) {
        th.done = true;
        return;
    }
    const std::uint16_t word    = program_[th.pc];
    const auto          decoded = isa::decode(word);

    TraceRecord rec{};
    rec.tick   = th.pc;
    rec.tid    = static_cast<std::uint8_t>(tid);
    rec.pc     = th.pc;
    rec.instr  = word;
    rec.rd     = 0xFF;  // sentinel = no register write

    const auto* spec = isa::lookup(static_cast<std::uint8_t>(decoded.op));
    rec.op = spec ? spec->mnemonic : std::string_view{"INVALID"};

    std::uint16_t next_pc = static_cast<std::uint16_t>(th.pc + 1);
    bool branch_taken = false;

    switch (decoded.op) {
        case isa::Opcode::NOP:
            break;
        case isa::Opcode::CMP: {
            const std::uint8_t rs = th.regs[decoded.rs];
            const std::uint8_t rt = th.regs[decoded.rt];
            th.nzp = static_cast<std::uint8_t>(alu_cmp(rs, rt) & 0x7);
            break;
        }
        case isa::Opcode::ADD:
        case isa::Opcode::SUB:
        case isa::Opcode::MUL:
        case isa::Opcode::DIV: {
            const std::uint8_t rs = th.regs[decoded.rs];
            const std::uint8_t rt = th.regs[decoded.rt];
            const std::uint8_t v  = alu_arith(decoded.alu_arithmetic_mux, rs, rt);
            th.regs[decoded.rd] = v;
            rec.rd     = decoded.rd;
            rec.rd_val = v;
            break;
        }
        case isa::Opcode::LDR: {
            const std::uint16_t addr = th.regs[decoded.rs];
            const std::uint8_t  v    = memory_.load(addr);
            th.regs[decoded.rd] = v;
            rec.rd     = decoded.rd;
            rec.rd_val = v;
            break;
        }
        case isa::Opcode::STR: {
            const std::uint16_t addr = th.regs[decoded.rs];
            const std::uint8_t  v    = th.regs[decoded.rt];
            memory_.store(addr, v);
            rec.mem_w = std::make_pair(static_cast<std::uint8_t>(addr), v);
            break;
        }
        case isa::Opcode::CONST: {
            th.regs[decoded.rd] = decoded.imm8;
            rec.rd     = decoded.rd;
            rec.rd_val = decoded.imm8;
            break;
        }
        case isa::Opcode::BRnzp: {
            if ((th.nzp & decoded.nzp) != 0) {
                next_pc      = static_cast<std::uint16_t>(decoded.imm9 & 0xFF);
                branch_taken = true;
            }
            break;
        }
        case isa::Opcode::RET: {
            th.done = true;
            break;
        }
    }

    rec.nzp  = th.nzp;
    rec.done = th.done;
    if (trace != nullptr) trace->emit(rec);

    if (!th.done) {
        th.pc = next_pc;
    }
    static_cast<void>(branch_taken);
}

}  // namespace opengpu::ref
