#include "opengpu/trace.hpp"

#include <stdexcept>

namespace opengpu::ref {

TraceSink::TraceSink(const std::string& path) : out_(path, std::ios::out | std::ios::trunc) {
    if (!out_) {
        throw std::runtime_error("cannot open trace file: " + path);
    }
}

TraceSink::~TraceSink() = default;

void TraceSink::emit(const TraceRecord& r) {
    // Hand-rolled JSON: avoids pulling nlohmann/json for one-line records.
    // Schema is documented in include/opengpu/trace.hpp.
    out_ << "{\"tick\":" << r.tick
         << ",\"tid\":"  << static_cast<int>(r.tid)
         << ",\"pc\":"   << r.pc
         << ",\"instr\":" << r.instr
         << ",\"op\":\"" << r.op << "\""
         << ",\"rd\":"   << static_cast<int>(r.rd)
         << ",\"rd_val\":" << static_cast<int>(r.rd_val)
         << ",\"mem_w\":";
    if (r.mem_w.has_value()) {
        out_ << "{\"addr\":" << static_cast<int>(r.mem_w->first)
             << ",\"val\":"  << static_cast<int>(r.mem_w->second) << "}";
    } else {
        out_ << "null";
    }
    out_ << ",\"nzp\":" << static_cast<int>(r.nzp)
         << ",\"done\":" << (r.done ? "true" : "false")
         << "}\n";
}

}  // namespace opengpu::ref
