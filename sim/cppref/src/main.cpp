// opengpu-refsim CLI driver.
//
// Usage:
//   opengpu-refsim --program program.hex [--data data.hex] [--threads N]
//                  [--blocks B] [--trace trace.jsonl] [--max-steps N]
//
// Exit code:
//   0 on success, 1 on any error.

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include "opengpu/core.hpp"
#include "opengpu/loader.hpp"
#include "opengpu/memory.hpp"
#include "opengpu/trace.hpp"

namespace {

struct Args {
    std::filesystem::path program;
    std::filesystem::path data;     // optional
    std::filesystem::path trace;    // optional
    int  threads   = 1;
    int  blocks    = 1;
    int  max_steps = 100000;
    int  mem_size  = 256;
};

[[nodiscard]] bool parse(int argc, char** argv, Args& a) {
    for (int i = 1; i < argc; ++i) {
        const std::string s = argv[i];
        auto next = [&](const char* flag) -> const char* {
            if (++i >= argc) {
                std::cerr << "missing value for " << flag << "\n";
                return nullptr;
            }
            return argv[i];
        };
        if      (s == "--program") { auto v = next("--program"); if (!v) return false; a.program = v; }
        else if (s == "--data")    { auto v = next("--data");    if (!v) return false; a.data    = v; }
        else if (s == "--trace")   { auto v = next("--trace");   if (!v) return false; a.trace   = v; }
        else if (s == "--threads") { auto v = next("--threads"); if (!v) return false; a.threads = std::atoi(v); }
        else if (s == "--blocks")  { auto v = next("--blocks");  if (!v) return false; a.blocks  = std::atoi(v); }
        else if (s == "--max-steps") { auto v = next("--max-steps"); if (!v) return false; a.max_steps = std::atoi(v); }
        else if (s == "--mem-size")  { auto v = next("--mem-size");  if (!v) return false; a.mem_size  = std::atoi(v); }
        else if (s == "-h" || s == "--help") {
            std::cout << "Usage: opengpu-refsim --program FILE "
                         "[--data FILE] [--threads N] [--blocks N] "
                         "[--trace FILE] [--max-steps N] [--mem-size N]\n";
            return false;
        }
        else { std::cerr << "unknown arg: " << s << "\n"; return false; }
    }
    if (a.program.empty()) { std::cerr << "--program is required\n"; return false; }
    if (a.threads <= 0 || a.threads > 255) { std::cerr << "--threads out of range\n"; return false; }
    if (a.blocks  <= 0 || a.blocks  > 255) { std::cerr << "--blocks out of range\n";  return false; }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Args a;
    if (!parse(argc, argv, a)) return 1;

    try {
        auto program = opengpu::ref::load_program(a.program);
        opengpu::ref::Memory mem(static_cast<std::size_t>(a.mem_size));
        if (!a.data.empty()) {
            auto data = opengpu::ref::load_data(a.data);
            for (std::size_t i = 0; i < data.size() && i < mem.size(); ++i) {
                mem.raw()[i] = data[i];
            }
        }

        std::unique_ptr<opengpu::ref::TraceSink> trace;
        if (!a.trace.empty()) {
            trace = std::make_unique<opengpu::ref::TraceSink>(a.trace.string());
        }

        std::uint64_t total_retired = 0;
        for (int b = 0; b < a.blocks; ++b) {
            opengpu::ref::CoreConfig cfg{
                .block_idx  = static_cast<std::uint8_t>(b),
                .block_dim  = static_cast<std::uint8_t>(a.threads),
                .max_steps  = static_cast<std::uint32_t>(a.max_steps),
            };
            opengpu::ref::Core core(cfg, program, mem);
            total_retired += core.run(trace.get());
        }

        std::cout << "retired_instructions=" << total_retired << "\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "refsim error: " << e.what() << "\n";
        return 1;
    }
}
