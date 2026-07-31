#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace t1report {

// Money is carried as an exact integer number of cents, never as a double.
//
// Both drivers hand decimals back as strings. Parsing those to double and
// summing them would make the totals depend on floating-point rounding, and
// since the whole point of this tool is that its two outputs can be diffed
// byte-for-byte, a one-cent difference in the last row would be
// indistinguishable from a real migration defect. Integer cents keep the
// arithmetic exact.
using Cents = std::int64_t;

// Parses "-1234.56", "1234.5", "1234" or "" into cents. Throws
// std::invalid_argument on anything else, so a driver returning an unexpected
// format fails loudly rather than silently reporting zero.
Cents parse_money(std::string_view text);

// Formats cents back as a fixed two-decimal string, e.g. -123456 -> "-1234.56".
std::string format_money(Cents cents);

}  // namespace t1report
