#include "t1report/query.hpp"

#include <string>

namespace t1report {

// Portability notes, all of them load-bearing:
//
//   * Unquoted identifiers fold to lower case in PostgreSQL and are matched
//     case-insensitively in SQL Server, so the PascalCase names read naturally
//     and resolve on both.
//   * COALESCE, not ISNULL - COALESCE is standard and SQL Server supports it.
//   * No TOP and no LIMIT: the row count is bounded by the WHERE clause.
//   * The province filter is expressed as "(param IS NULL OR column = param)"
//     so one statement covers both the filtered and unfiltered cases without
//     string-building, which keeps the value bound rather than interpolated.
//   * That parameter is wrapped in CAST(... AS VARCHAR(2)). PostgreSQL cannot
//     infer a type for a parameter whose only use is "IS NULL" and rejects the
//     statement outright; the standard CAST gives it one and SQL Server accepts
//     the same spelling. A PostgreSQL-style ::varchar would not have been
//     portable.
const char* const kT1RegisterSqlTemplate =
    "SELECT c.ClientCode, c.DisplayName, r.ProvinceOfResidence, r.TaxableIncome, "
    "r.FederalTax, r.ProvincialTax, "
    "COALESCE(r.FederalCredits, 0) + COALESCE(r.ProvincialCredits, 0) AS Credits, "
    "r.BalanceOwing, r.FilingStatus "
    "FROM tax.T1Return AS r "
    "JOIN client.Client AS c ON c.ClientId = r.ClientId "
    "WHERE r.TaxYear = {1} "
    "AND (CAST({2} AS VARCHAR(2)) IS NULL "
    "     OR r.ProvinceOfResidence = CAST({2} AS VARCHAR(2))) "
    "ORDER BY c.ClientCode";

std::string render_sql(const char* tmpl, bool style_dollar) {
    std::string out;
    // ODBC positional markers are all '?', so a parameter referenced twice in
    // the template has to be bound twice. That is why the province parameter is
    // bound at two positions in the ODBC backend and only once in libpq.
    for (const char* p = tmpl; *p != '\0'; ++p) {
        if (*p == '{') {
            const char* close = p;
            while (*close != '\0' && *close != '}') ++close;
            if (*close == '}') {
                const std::string index(p + 1, close);
                out += style_dollar ? ("$" + index) : "?";
                p = close;
                continue;
            }
        }
        out += *p;
    }
    return out;
}

}  // namespace t1report
