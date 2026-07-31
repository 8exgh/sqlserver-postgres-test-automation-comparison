#pragma once

#include <string>

namespace t1report {

// The one SQL statement this tool runs, written so it is valid on both engines.
//
// Verified: this text executes unchanged on SQL Server 2022 and PostgreSQL 16
// and returns identical values. Unquoted identifiers fold case-insensitively on
// both, the schema and column names are the same on both sides, and the query
// deliberately avoids every construct where the dialects diverge - no TOP or
// LIMIT, no ISNULL, no + for string concatenation, no date literals.
//
// Parameter placeholders are the single exception, so they are written as {1}
// and {2} here and rewritten per driver. Keeping that difference in one visible
// place is the point: two copies of the query would drift.
//
//   {1}  tax year
//   {2}  province code, or NULL for all provinces
extern const char* const kT1RegisterSqlTemplate;

// Column indices in the result set, shared by both backends.
enum T1Column : int {
    kClientCode = 0,
    kDisplayName = 1,
    kProvince = 2,
    kTaxableIncome = 3,
    kFederalTax = 4,
    kProvincialTax = 5,
    kCredits = 6,
    kBalanceOwing = 7,
    kFilingStatus = 8,
    kColumnCount = 9,
};

// Replaces {n} with the driver's placeholder syntax:
//   style_dollar -> $1, $2   (libpq)
//   style_qmark  -> ?, ?     (ODBC)
std::string render_sql(const char* tmpl, bool style_dollar);

}  // namespace t1report
