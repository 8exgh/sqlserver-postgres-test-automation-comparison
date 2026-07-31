#pragma once

#include <string>
#include <vector>

#include "t1report/money.hpp"

namespace t1report {

// One row of the T1 assessment register, in the order the report prints them.
// The column order here is the contract the two backends both fill.
struct T1Row {
    std::string client_code;
    std::string display_name;
    std::string province;
    Cents taxable_income = 0;
    Cents federal_tax = 0;
    Cents provincial_tax = 0;
    Cents credits = 0;
    Cents balance_owing = 0;
    std::string filing_status;
};

// A subtotal line, used for both the per-province groups and the grand total.
struct Totals {
    std::size_t count = 0;
    Cents taxable_income = 0;
    Cents federal_tax = 0;
    Cents provincial_tax = 0;
    Cents credits = 0;
    Cents balance_owing = 0;

    void add(const T1Row& row);
};

struct ReportData {
    std::string source_description;  // engine, version and endpoint, for the header
    int tax_year = 0;
    std::string province_filter;     // empty when unfiltered
    std::vector<T1Row> rows;         // already ordered by client code
};

}  // namespace t1report
