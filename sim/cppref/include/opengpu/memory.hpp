// Memory model for the OpenGPU C++ reference simulator.
//
// Mirrors the unified 8-bit address space exposed by the RTL LSU
// (256 bytes by default; configurable so larger programs can run in
// the host-side ref model without touching RTL parameters).

#pragma once

#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace opengpu::ref {

class Memory {
public:
    explicit Memory(std::size_t size);

    [[nodiscard]] std::uint8_t  load (std::uint16_t addr) const;
    void                        store(std::uint16_t addr, std::uint8_t value);

    [[nodiscard]] std::size_t   size() const noexcept { return data_.size(); }
    [[nodiscard]] const std::vector<std::uint8_t>& raw() const noexcept { return data_; }
    [[nodiscard]] std::vector<std::uint8_t>& raw() noexcept { return data_; }

private:
    std::vector<std::uint8_t> data_;
};

class OutOfRange : public std::out_of_range {
public:
    using std::out_of_range::out_of_range;
};

}  // namespace opengpu::ref
