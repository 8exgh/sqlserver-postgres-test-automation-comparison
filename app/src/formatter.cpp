#include "t1report/formatter.hpp"

#include <algorithm>
#include <iomanip>
#include <ostream>
#include <string>
#include <vector>

#include "t1report/money.hpp"
#include "t1report/rows.hpp"

namespace t1report {

void Totals::add(const T1Row& row) {
    ++count;
    taxable_income += row.taxable_income;
    federal_tax += row.federal_tax;
    provincial_tax += row.provincial_tax;
    credits += row.credits;
    balance_owing += row.balance_owing;
}

namespace {

constexpr int kCodeWidth = 11;
constexpr int kNameWidth = 22;
constexpr int kProvWidth = 4;
constexpr int kMoneyWidth = 15;
constexpr int kStatusWidth = 11;
constexpr int kTableWidth =
    kCodeWidth + kNameWidth + kProvWidth + kMoneyWidth * 5 + kStatusWidth;

void pad_left(std::ostream& out, const std::string& s, int width) {
    // Truncate rather than wrap, so a long name can never break the alignment.
    const auto w = static_cast<std::size_t>(width);
    if (s.size() >= w) {
        out << s.substr(0, w - 1) << ' ';
    } else {
        out << s << std::string(w - s.size(), ' ');
    }
}

void pad_right(std::ostream& out, const std::string& s, int width) {
    const auto w = static_cast<std::size_t>(width);
    if (s.size() >= w) {
        out << s;
    } else {
        out << std::string(w - s.size(), ' ') << s;
    }
}

void write_totals_line(std::ostream& out, const std::string& label, const Totals& t) {
    std::string lead = label + " (" + std::to_string(t.count) + ")";
    pad_left(out, lead, kCodeWidth + kNameWidth + kProvWidth);
    pad_right(out, format_money(t.taxable_income), kMoneyWidth);
    pad_right(out, format_money(t.federal_tax), kMoneyWidth);
    pad_right(out, format_money(t.provincial_tax), kMoneyWidth);
    pad_right(out, format_money(t.credits), kMoneyWidth);
    pad_right(out, format_money(t.balance_owing), kMoneyWidth);
    out << '\n';
}

// RFC 4180: quote only when the value contains a comma, quote or newline, and
// escape an embedded quote by doubling it. Several client names in this data
// contain a comma ("Chen, Amelia"), so this path is exercised on every run.
std::string csv_escape(const std::string& value) {
    const bool needs_quotes =
        value.find_first_of(",\"\n\r") != std::string::npos;
    if (!needs_quotes) return value;

    std::string out;
    out.reserve(value.size() + 2);
    out += '"';
    for (const char ch : value) {
        if (ch == '"') out += '"';
        out += ch;
    }
    out += '"';
    return out;
}

}  // namespace

void write_text(std::ostream& out, const ReportData& data) {
    out << "CANADIAN TAX PRACTICE - T1 ASSESSMENT REGISTER\n";
    out << "Source: " << data.source_description << '\n';
    out << "Tax year: " << data.tax_year;
    if (!data.province_filter.empty()) out << "   Province: " << data.province_filter;
    out << "\n\n";

    pad_left(out, "CLIENT", kCodeWidth);
    pad_left(out, "NAME", kNameWidth);
    pad_left(out, "PR", kProvWidth);
    pad_right(out, "TAXABLE INCOME", kMoneyWidth);
    pad_right(out, "FEDERAL", kMoneyWidth);
    pad_right(out, "PROVINCIAL", kMoneyWidth);
    pad_right(out, "CREDITS", kMoneyWidth);
    pad_right(out, "BALANCE", kMoneyWidth);
    out << "  STATUS\n";
    out << std::string(static_cast<std::size_t>(kTableWidth), '-') << '\n';

    if (data.rows.empty()) {
        out << "(no returns matched)\n";
        out << std::string(static_cast<std::size_t>(kTableWidth), '-') << '\n';
        Totals empty;
        write_totals_line(out, "TOTAL", empty);
        return;
    }

    Totals grand;

    for (const auto& row : data.rows) {
        grand.add(row);

        pad_left(out, row.client_code, kCodeWidth);
        pad_left(out, row.display_name, kNameWidth);
        pad_left(out, row.province, kProvWidth);
        pad_right(out, format_money(row.taxable_income), kMoneyWidth);
        pad_right(out, format_money(row.federal_tax), kMoneyWidth);
        pad_right(out, format_money(row.provincial_tax), kMoneyWidth);
        pad_right(out, format_money(row.credits), kMoneyWidth);
        pad_right(out, format_money(row.balance_owing), kMoneyWidth);
        out << "  " << row.filing_status << '\n';
    }

    out << std::string(static_cast<std::size_t>(kTableWidth), '-') << '\n';
    write_totals_line(out, "TOTALS", grand);

    // Per-province summary, computed over the whole set so it does not depend
    // on row order.
    std::vector<std::string> provinces;
    for (const auto& row : data.rows) {
        if (std::find(provinces.begin(), provinces.end(), row.province) == provinces.end()) {
            provinces.push_back(row.province);
        }
    }
    std::sort(provinces.begin(), provinces.end());

    if (provinces.size() > 1) {
        out << "\nBY PROVINCE\n";
        for (const auto& code : provinces) {
            Totals t;
            for (const auto& row : data.rows) {
                if (row.province == code) t.add(row);
            }
            write_totals_line(out, code, t);
        }
    }
}

void write_csv(std::ostream& out, const ReportData& data) {
    // No header comment lines and no source description: the CSV is what gets
    // diffed between engines, so it must contain only the data. Anything
    // naming the engine would make every diff fail.
    out << "client_code,display_name,province,taxable_income,federal_tax,"
           "provincial_tax,credits,balance_owing,filing_status\n";

    for (const auto& row : data.rows) {
        out << csv_escape(row.client_code) << ','
            << csv_escape(row.display_name) << ','
            << csv_escape(row.province) << ','
            << format_money(row.taxable_income) << ','
            << format_money(row.federal_tax) << ','
            << format_money(row.provincial_tax) << ','
            << format_money(row.credits) << ','
            << format_money(row.balance_owing) << ','
            << csv_escape(row.filing_status) << '\n';
    }

    Totals grand;
    for (const auto& row : data.rows) grand.add(row);

    out << "TOTAL," << grand.count << ",,"
        << format_money(grand.taxable_income) << ','
        << format_money(grand.federal_tax) << ','
        << format_money(grand.provincial_tax) << ','
        << format_money(grand.credits) << ','
        << format_money(grand.balance_owing) << ",\n";
}

void write_report(std::ostream& out, const ReportData& data, Format format) {
    switch (format) {
        case Format::Csv:
            write_csv(out, data);
            break;
        case Format::Text:
            write_text(out, data);
            break;
    }
}

}  // namespace t1report
