#include <libpq-fe.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "t1report/config.hpp"
#include "t1report/datasource.hpp"
#include "t1report/money.hpp"
#include "t1report/query.hpp"
#include "t1report/rows.hpp"

namespace t1report {
namespace {

struct PgConnDeleter {
    void operator()(PGconn* c) const noexcept { PQfinish(c); }
};
struct PgResultDeleter {
    void operator()(PGresult* r) const noexcept { PQclear(r); }
};

using PgConn = std::unique_ptr<PGconn, PgConnDeleter>;
using PgResult = std::unique_ptr<PGresult, PgResultDeleter>;

std::string trim_trailing_newline(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
    return s;
}

class PostgresSource final : public IDataSource {
public:
    void connect(const ConnectionConfig& config) override {
        // The parameterised form rather than a connection string: values with
        // spaces, quotes or backslashes in a password need no escaping here.
        const char* keys[] = {"host", "port", "dbname", "user", "password",
                              "application_name", nullptr};
        const char* values[] = {config.host.c_str(), config.port.c_str(),
                                config.database.c_str(), config.user.c_str(),
                                config.password.c_str(), "t1report", nullptr};

        conn_.reset(PQconnectdbParams(keys, values, /*expand_dbname=*/0));
        if (conn_ == nullptr) {
            throw ConnectionError("libpq could not allocate a connection");
        }
        if (PQstatus(conn_.get()) != CONNECTION_OK) {
            throw ConnectionError(trim_trailing_newline(PQerrorMessage(conn_.get())));
        }
        endpoint_ = config.host + ":" + config.port + "/" + config.database;
    }

    std::string describe() const override {
        if (conn_ == nullptr) return "PostgreSQL (not connected)";
        const int v = PQserverVersion(conn_.get());
        // Since PostgreSQL 10 the encoding is MMmmmm, e.g. 160014 -> 16.14.
        const int major = v / 10000;
        const int minor = v % 10000;
        return "PostgreSQL " + std::to_string(major) + "." + std::to_string(minor) +
               " (" + endpoint_ + ")";
    }

    std::vector<T1Row> fetch_t1_register(
        int tax_year, const std::optional<std::string>& province) override {
        const std::string sql = render_sql(kT1RegisterSqlTemplate, /*style_dollar=*/true);

        const std::string year_text = std::to_string(tax_year);
        // libpq takes a NULL parameter as a null pointer, which is exactly what
        // the query's "($2 IS NULL OR ...)" branch is written for.
        const char* params[2] = {
            year_text.c_str(),
            province.has_value() ? province->c_str() : nullptr,
        };

        PgResult res(PQexecParams(conn_.get(), sql.c_str(), 2, nullptr, params,
                                  nullptr, nullptr, /*resultFormat=*/0));
        if (res == nullptr) {
            throw QueryError("libpq returned no result (out of memory?)");
        }
        if (PQresultStatus(res.get()) != PGRES_TUPLES_OK) {
            throw QueryError(trim_trailing_newline(PQresultErrorMessage(res.get())));
        }
        if (PQnfields(res.get()) != kColumnCount) {
            throw QueryError("expected " + std::to_string(kColumnCount) +
                             " columns, got " + std::to_string(PQnfields(res.get())));
        }

        const int rows = PQntuples(res.get());
        std::vector<T1Row> out;
        out.reserve(static_cast<std::size_t>(rows));

        for (int i = 0; i < rows; ++i) {
            auto text = [&](int col) -> std::string {
                if (PQgetisnull(res.get(), i, col) == 1) return {};
                return PQgetvalue(res.get(), i, col);
            };

            T1Row row;
            row.client_code = text(kClientCode);
            row.display_name = text(kDisplayName);
            row.province = text(kProvince);
            row.taxable_income = parse_money(text(kTaxableIncome));
            row.federal_tax = parse_money(text(kFederalTax));
            row.provincial_tax = parse_money(text(kProvincialTax));
            row.credits = parse_money(text(kCredits));
            row.balance_owing = parse_money(text(kBalanceOwing));
            row.filing_status = text(kFilingStatus);
            out.push_back(std::move(row));
        }
        return out;
    }

private:
    PgConn conn_;
    std::string endpoint_;
};

}  // namespace

std::unique_ptr<IDataSource> make_postgres_source() {
    return std::make_unique<PostgresSource>();
}

}  // namespace t1report
