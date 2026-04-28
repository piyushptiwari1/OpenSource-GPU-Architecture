#include "opengpu/loader.hpp"

#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace opengpu::ref {

namespace {

[[nodiscard]] std::string strip_comments(std::string line) {
    auto hash = line.find('#');
    if (hash != std::string::npos) line.resize(hash);
    auto slash = line.find("//");
    if (slash != std::string::npos) line.resize(slash);
    return line;
}

template <typename Word>
[[nodiscard]] std::vector<Word> load_hex(const std::filesystem::path& p, int max_bits) {
    std::ifstream in(p);
    if (!in) {
        throw std::runtime_error("cannot open hex file: " + p.string());
    }
    std::vector<Word> out;
    std::string raw;
    std::size_t lineno = 0;
    while (std::getline(in, raw)) {
        ++lineno;
        std::string s = strip_comments(raw);
        std::istringstream iss(s);
        std::string tok;
        while (iss >> tok) {
            unsigned long long v = 0;
            try {
                v = std::stoull(tok, nullptr, 16);
            } catch (const std::exception&) {
                throw std::runtime_error("malformed hex literal at " +
                                         p.string() + ":" + std::to_string(lineno) +
                                         " (" + tok + ")");
            }
            const unsigned long long mask =
                (max_bits >= 64) ? ~0ULL : ((1ULL << max_bits) - 1);
            if (v > mask) {
                throw std::runtime_error("hex literal exceeds " +
                                         std::to_string(max_bits) + " bits at " +
                                         p.string() + ":" + std::to_string(lineno));
            }
            out.push_back(static_cast<Word>(v));
        }
    }
    return out;
}

}  // namespace

std::vector<std::uint16_t> load_program(const std::filesystem::path& p) {
    return load_hex<std::uint16_t>(p, 16);
}

std::vector<std::uint8_t> load_data(const std::filesystem::path& p) {
    return load_hex<std::uint8_t>(p, 8);
}

}  // namespace opengpu::ref
