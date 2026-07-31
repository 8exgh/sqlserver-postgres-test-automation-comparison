#pragma once

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "t1report/config.hpp"
#include "t1report/rows.hpp"

namespace t1report {

// The only thing the report knows about a database.
//
// main picks an implementation from --engine and nothing downstream of that
// point is engine-aware: the formatter, the totals and the row struct are the
// same whichever side the data came from. That is what makes the two outputs
// comparable - any difference has to come from the data, not from the code
// that printed it.
class IDataSource {
public:
    virtual ~IDataSource() = default;

    IDataSource() = default;
    IDataSource(const IDataSource&) = delete;
    IDataSource& operator=(const IDataSource&) = delete;

    // Throws ConnectionError on failure.
    virtual void connect(const ConnectionConfig& config) = 0;

    // Server product and version plus the endpoint, for the report header.
    virtual std::string describe() const = 0;

    // Throws QueryError on failure. Rows come back ordered by client code.
    virtual std::vector<T1Row> fetch_t1_register(
        int tax_year, const std::optional<std::string>& province) = 0;
};

std::unique_ptr<IDataSource> make_data_source(Engine engine);

}  // namespace t1report
