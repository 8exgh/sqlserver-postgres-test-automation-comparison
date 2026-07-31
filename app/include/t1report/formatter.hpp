#pragma once

#include <iosfwd>

#include "t1report/config.hpp"
#include "t1report/rows.hpp"

namespace t1report {

// Renders the report. Both writers are deterministic and engine-agnostic, so
// two runs against different databases differ only where the data differs.
void write_text(std::ostream& out, const ReportData& data);
void write_csv(std::ostream& out, const ReportData& data);

void write_report(std::ostream& out, const ReportData& data, Format format);

}  // namespace t1report
