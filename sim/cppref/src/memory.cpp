#include "opengpu/memory.hpp"

namespace opengpu::ref {

Memory::Memory(std::size_t size) : data_(size, 0) {}

std::uint8_t Memory::load(std::uint16_t addr) const {
    if (addr >= data_.size()) {
        throw OutOfRange("memory load out of range");
    }
    return data_[addr];
}

void Memory::store(std::uint16_t addr, std::uint8_t value) {
    if (addr >= data_.size()) {
        throw OutOfRange("memory store out of range");
    }
    data_[addr] = value;
}

}  // namespace opengpu::ref
