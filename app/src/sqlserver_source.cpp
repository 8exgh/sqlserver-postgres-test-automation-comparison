#include <sql.h>
#include <sqlext.h>

#include <cstring>
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

// Reads the driver's own diagnostic records. Without this every ODBC failure
// reports as a bare "-1", which is useless; with it the caller gets the
// SQLSTATE and the message FreeTDS or the server actually produced.
std::string diagnostics(SQLSMALLINT handle_type, SQLHANDLE handle) {
    std::string out;
    for (SQLSMALLINT rec = 1;; ++rec) {
        SQLCHAR state[7] = {};
        SQLINTEGER native = 0;
        SQLCHAR message[SQL_MAX_MESSAGE_LENGTH] = {};
        SQLSMALLINT length = 0;

        const SQLRETURN rc = SQLGetDiagRec(handle_type, handle, rec, state, &native,
                                           message, sizeof(message), &length);
        if (rc == SQL_NO_DATA || (rc != SQL_SUCCESS && rc != SQL_SUCCESS_WITH_INFO)) break;

        if (!out.empty()) out += "; ";
        out += "[";
        out += reinterpret_cast<const char*>(state);
        out += "] ";
        out += reinterpret_cast<const char*>(message);
    }
    if (out.empty()) out = "no diagnostic information available";
    return out;
}

bool succeeded(SQLRETURN rc) {
    return rc == SQL_SUCCESS || rc == SQL_SUCCESS_WITH_INFO;
}

// RAII for the three handle kinds, so an exception on any error path still
// frees them in the right order (statement, connection, environment).
class Handle {
public:
    Handle() = default;
    Handle(SQLSMALLINT type, SQLHANDLE parent) : type_(type) {
        if (!succeeded(SQLAllocHandle(type, parent, &handle_))) {
            throw ConnectionError("could not allocate an ODBC handle");
        }
    }
    ~Handle() { reset(); }

    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;

    // Movable so a handle can be created locally and then installed into a
    // member; copying one would double-free it.
    Handle(Handle&& other) noexcept : type_(other.type_), handle_(other.handle_) {
        other.type_ = 0;
        other.handle_ = SQL_NULL_HANDLE;
    }
    Handle& operator=(Handle&& other) noexcept {
        if (this != &other) {
            reset();
            type_ = other.type_;
            handle_ = other.handle_;
            other.type_ = 0;
            other.handle_ = SQL_NULL_HANDLE;
        }
        return *this;
    }

    void reset() noexcept {
        if (handle_ != SQL_NULL_HANDLE) {
            if (type_ == SQL_HANDLE_DBC) SQLDisconnect(handle_);
            SQLFreeHandle(type_, handle_);
            handle_ = SQL_NULL_HANDLE;
        }
    }

    SQLHANDLE get() const noexcept { return handle_; }
    SQLSMALLINT type() const noexcept { return type_; }
    explicit operator bool() const noexcept { return handle_ != SQL_NULL_HANDLE; }

private:
    SQLSMALLINT type_ = 0;
    SQLHANDLE handle_ = SQL_NULL_HANDLE;
};

class SqlServerSource final : public IDataSource {
public:
    void connect(const ConnectionConfig& config) override {
        env_ = Handle(SQL_HANDLE_ENV, SQL_NULL_HANDLE);
        if (!succeeded(SQLSetEnvAttr(env_.get(), SQL_ATTR_ODBC_VERSION,
                                     reinterpret_cast<SQLPOINTER>(SQL_OV_ODBC3), 0))) {
            throw ConnectionError("could not select ODBC 3.x behaviour");
        }

        dbc_ = Handle(SQL_HANDLE_DBC, env_.get());

        // DSN-less, so nothing has to be registered in odbc.ini - only the
        // driver itself, which scripts/setup-odbc.sh writes into odbcinst.ini.
        //
        // TDS_Version=7.4 is what lets FreeTDS negotiate with SQL Server 2022;
        // without it the handshake falls back to an older protocol level.
        std::string conn_str =
            "DRIVER={" + driver_ + "}"
            ";SERVER=" + config.host +
            ";PORT=" + config.port +
            ";DATABASE=" + config.database +
            ";UID=" + config.user +
            ";PWD=" + config.password +
            ";TDS_Version=7.4";

        std::vector<SQLCHAR> in(conn_str.begin(), conn_str.end());
        in.push_back('\0');
        SQLCHAR out[1024] = {};
        SQLSMALLINT out_len = 0;

        const SQLRETURN rc =
            SQLDriverConnect(dbc_.get(), nullptr, in.data(), SQL_NTS, out, sizeof(out),
                             &out_len, SQL_DRIVER_NOPROMPT);
        if (!succeeded(rc)) {
            throw ConnectionError(diagnostics(SQL_HANDLE_DBC, dbc_.get()));
        }

        endpoint_ = config.host + ":" + config.port + "/" + config.database;
        version_ = query_scalar("SELECT CAST(SERVERPROPERTY('ProductVersion') AS VARCHAR(64))");
    }

    std::string describe() const override {
        if (!dbc_) return "SQL Server (not connected)";
        return "SQL Server " + (version_.empty() ? std::string("(unknown version)") : version_) +
               " (" + endpoint_ + ") [legacy]";
    }

    std::vector<T1Row> fetch_t1_register(
        int tax_year, const std::optional<std::string>& province) override {
        Handle stmt(SQL_HANDLE_STMT, dbc_.get());

        const std::string sql = render_sql(kT1RegisterSqlTemplate, /*style_dollar=*/false);
        std::vector<SQLCHAR> sql_buf(sql.begin(), sql.end());
        sql_buf.push_back('\0');

        if (!succeeded(SQLPrepare(stmt.get(), sql_buf.data(), SQL_NTS))) {
            throw QueryError(diagnostics(SQL_HANDLE_STMT, stmt.get()));
        }

        // Every ODBC placeholder is a bare '?', so the province appears twice in
        // the statement and has to be bound twice - unlike libpq, where $2 can
        // be referenced repeatedly. This is the one place the two backends
        // genuinely diverge.
        SQLINTEGER year_value = tax_year;
        SQLLEN year_ind = 0;
        if (!succeeded(SQLBindParameter(stmt.get(), 1, SQL_PARAM_INPUT, SQL_C_SLONG,
                                        SQL_INTEGER, 0, 0, &year_value, 0, &year_ind))) {
            throw QueryError(diagnostics(SQL_HANDLE_STMT, stmt.get()));
        }

        std::string prov = province.value_or(std::string{});
        // Buffers must outlive the SQLExecute call, which is why they are
        // declared here rather than inside the loop below.
        SQLLEN prov_ind = province.has_value()
                              ? static_cast<SQLLEN>(prov.size())
                              : SQL_NULL_DATA;
        // The province placeholder appears twice in the statement, so both
        // positions get the same buffer.
        const SQLUSMALLINT province_positions[] = {2, 3};
        for (SQLUSMALLINT position : province_positions) {
            if (!succeeded(SQLBindParameter(
                    stmt.get(), position, SQL_PARAM_INPUT, SQL_C_CHAR, SQL_VARCHAR, 2, 0,
                    prov.empty() ? nullptr : prov.data(),
                    static_cast<SQLLEN>(prov.size()), &prov_ind))) {
                throw QueryError(diagnostics(SQL_HANDLE_STMT, stmt.get()));
            }
        }

        if (!succeeded(SQLExecute(stmt.get()))) {
            throw QueryError(diagnostics(SQL_HANDLE_STMT, stmt.get()));
        }

        SQLSMALLINT columns = 0;
        if (!succeeded(SQLNumResultCols(stmt.get(), &columns))) {
            throw QueryError(diagnostics(SQL_HANDLE_STMT, stmt.get()));
        }
        if (columns != kColumnCount) {
            throw QueryError("expected " + std::to_string(kColumnCount) +
                             " columns, got " + std::to_string(columns));
        }

        std::vector<T1Row> out;
        for (;;) {
            const SQLRETURN rc = SQLFetch(stmt.get());
            if (rc == SQL_NO_DATA) break;
            if (!succeeded(rc)) {
                throw QueryError(diagnostics(SQL_HANDLE_STMT, stmt.get()));
            }

            // Everything is read as characters, including the decimals: the
            // server has already formatted them to the column's scale, and
            // going through SQL_C_DOUBLE would reintroduce the floating-point
            // rounding that integer cents exist to avoid.
            auto text = [&](int col) { return get_string(stmt, col); };

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
    static std::string get_string(const Handle& stmt, int column) {
        char buffer[512];
        SQLLEN indicator = 0;
        const SQLRETURN rc =
            SQLGetData(stmt.get(), static_cast<SQLUSMALLINT>(column + 1), SQL_C_CHAR,
                       buffer, sizeof(buffer), &indicator);
        if (!succeeded(rc)) {
            throw QueryError(diagnostics(SQL_HANDLE_STMT, stmt.get()));
        }
        if (indicator == SQL_NULL_DATA) return {};

        std::string value(buffer);
        // CHAR columns come back blank-padded to their declared width; the
        // province code in particular would otherwise be "ON  " and would not
        // match the PostgreSQL output.
        while (!value.empty() && value.back() == ' ') value.pop_back();
        return value;
    }

    std::string query_scalar(const std::string& sql) {
        Handle stmt(SQL_HANDLE_STMT, dbc_.get());
        std::vector<SQLCHAR> buf(sql.begin(), sql.end());
        buf.push_back('\0');
        if (!succeeded(SQLExecDirect(stmt.get(), buf.data(), SQL_NTS))) return {};
        if (SQLFetch(stmt.get()) == SQL_NO_DATA) return {};
        return get_string(stmt, 0);
    }

    Handle env_;
    Handle dbc_;
    std::string endpoint_;
    std::string version_;
    std::string driver_ = "FreeTDS";
};

}  // namespace

std::unique_ptr<IDataSource> make_sqlserver_source() {
    return std::make_unique<SqlServerSource>();
}

}  // namespace t1report
