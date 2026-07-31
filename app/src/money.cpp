#include "t1report/money.hpp"

#include <cctype>
#include <cstdlib>
#include <stdexcept>
#include <string>

namespace t1report {
namespace {

[[noreturn]] void reject(std::string_view text) {
    throw std::invalid_argument("not a decimal value: '" + std::string(text) + "'");
}

}  // namespace

Cents parse_money(std::string_view text) {
    // Trim: ODBC pads fixed-width character columns, and either driver may hand
    // back surrounding whitespace.
    std::size_t begin = 0;
    std::size_t end = text.size();
    while (begin < end && std::isspace(static_cast<unsigned char>(text[begin]))) ++begin;
    while (end > begin && std::isspace(static_cast<unsigned char>(text[end - 1]))) --end;
    text = text.substr(begin, end - begin);

    if (text.empty()) return 0;  // SQL NULL

    bool negative = false;
    std::size_t i = 0;
    if (text[i] == '-' || text[i] == '+') {
        negative = (text[i] == '-');
        ++i;
    }

    Cents whole = 0;
    std::size_t digits = 0;
    for (; i < text.size() && std::isdigit(static_cast<unsigned char>(text[i])); ++i, ++digits) {
        whole = whole * 10 + (text[i] - '0');
    }
    if (digits == 0) reject(text);

    Cents frac = 0;
    if (i < text.size() && text[i] == '.') {
        ++i;
        // Read exactly two decimal places; every money column in this schema is
        // DECIMAL(n,2). A third digit would mean the query returned something
        // other than what the report expects, so it is an error rather than
        // something to round silently.
        int taken = 0;
        for (; i < text.size() && std::isdigit(static_cast<unsigned char>(text[i])); ++i) {
            if (taken < 2) {
                frac = frac * 10 + (text[i] - '0');
                ++taken;
            } else {
                reject(text);
            }
        }
        while (taken < 2) {  // "1234.5" -> 50 cents
            frac *= 10;
            ++taken;
        }
    }

    if (i != text.size()) reject(text);

    const Cents total = whole * 100 + frac;
    return negative ? -total : total;
}

std::string format_money(Cents cents) {
    const bool negative = cents < 0;
    // Negating in unsigned space so the most negative value cannot overflow.
    const auto magnitude = negative
        ? static_cast<std::uint64_t>(-(cents + 1)) + 1u
        : static_cast<std::uint64_t>(cents);

    const std::uint64_t whole = magnitude / 100u;
    const std::uint64_t frac = magnitude % 100u;

    std::string out;
    if (negative) out += '-';
    out += std::to_string(whole);
    out += '.';
    if (frac < 10u) out += '0';
    out += std::to_string(frac);
    return out;
}

}  // namespace t1report
