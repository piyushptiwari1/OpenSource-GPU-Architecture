// Hex loader for program / data files.
//
// Format: one 16-bit (program) or 8-bit (data) value per line, hex
// without prefix. Blank lines and `#`/`//` comments are skipped.
// This matches the simple format already used by the cocotb tests.

#pragma once

#include <cstdint>
#include <filesystem>
#include <vector>

namespace opengpu::ref {

[[nodiscard]] std::vector<std::uint16_t> load_program(const std::filesystem::path& p);
[[nodiscard]] std::vector<std::uint8_t>  load_data   (const std::filesystem::path& p);

}  // namespace opengpu::ref
