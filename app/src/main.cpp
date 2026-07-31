#include <cstdlib>
#include <exception>
#include <iostream>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "t1report/config.hpp"
#include "t1report/datasource.hpp"
#include "t1report/formatter.hpp"
#include "t1report/rows.hpp"

namespace t1report {

std::unique_ptr<IDataSource> make_postgres_source();
std::unique_ptr<IDataSource> make_sqlserver_source();

std::string to_string(Engine engine) {
    return engine == Engine::Postgres ? "postgres" : "sqlserver";
}

std::unique_ptr<IDataSource> make_data_source(Engine engine) {
    return engine == Engine::Postgres ? make_postgres_source() : make_sqlserver_source();
}

namespace {

// Exit codes are distinct so a script can tell the failure modes apart: a
// harness needs "the database is down" (3) to read differently from "the query
// no longer matches the schema" (4).
constexpr int kExitOk = 0;
constexpr int kExitUsage = 2;
constexpr int kExitConnection = 3;
constexpr int kExitQuery = 4;

const char kUsage[] =
    "t1report - T1 assessment register from SQL Server or PostgreSQL\n"
    "\n"
    "usage: t1report --engine {postgres|sqlserver} [options]\n"
    "\n"
    "  --engine E        database to read from: postgres or sqlserver\n"
    "  --legacy          shorthand for --engine sqlserver\n"
    "  --year N          tax year to report               (default 2024)\n"
    "  --province XX     restrict to one province code    (default all)\n"
    "  --format F        text or csv                      (default text)\n"
    "  --host H          server host\n"
    "  --port P          server port\n"
    "  --database D      database name\n"
    "  --user U          user name\n"
    "  --password P      password (prefer the environment; argv is world-readable)\n"
    "  -h, --help        this message\n"
    "\n"
    "Connection defaults come from the environment, then from this repo's\n"
    "docker-compose.yml:\n"
    "  postgres   PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD\n"
    "             (localhost:15432/cdntaxpractice as postgres)\n"
    "  sqlserver  MSSQL_HOST MSSQL_PORT MSSQL_DB MSSQL_USER MSSQL_SA_PASSWORD\n"
    "             (localhost:11433/CdnTaxPractice as sa)\n"
    "\n"
    "The csv output contains only data - no engine name - so the two engines\n"
    "can be diffed directly:\n"
    "  t1report --engine postgres  --format csv > pg.csv\n"
    "  t1report --engine sqlserver --format csv > ss.csv\n"
    "  diff pg.csv ss.csv\n";

std::string env_or(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    return (value != nullptr && *value != '\0') ? std::string(value) : fallback;
}

ConnectionConfig default_connection(Engine engine) {
    if (engine == Engine::Postgres) {
        return {env_or("PGHOST", "localhost"), env_or("PGPORT", "15432"),
                env_or("PGDATABASE", "cdntaxpractice"), env_or("PGUSER", "postgres"),
                env_or("PGPASSWORD", "Str0ng!Passw0rd")};
    }
    return {env_or("MSSQL_HOST", "localhost"), env_or("MSSQL_PORT", "11433"),
            env_or("MSSQL_DB", "CdnTaxPractice"), env_or("MSSQL_USER", "sa"),
            env_or("MSSQL_SA_PASSWORD", "Str0ng!Passw0rd")};
}

// Returns the value for an option that requires one, or throws with the option
// named so the message says which argument was incomplete.
std::string take_value(const std::vector<std::string>& args, std::size_t& i) {
    const std::string& flag = args[i];
    if (i + 1 >= args.size()) throw UsageError(flag + " requires a value");
    return args[++i];
}

int parse_year(const std::string& text) {
    try {
        std::size_t consumed = 0;
        const int year = std::stoi(text, &consumed);
        if (consumed != text.size()) throw std::invalid_argument("trailing characters");
        return year;
    } catch (const std::exception&) {
        throw UsageError("--year expects a whole number, got '" + text + "'");
    }
}

struct ParseResult {
    ReportOptions options;
    bool help = false;
};

ParseResult parse_arguments(const std::vector<std::string>& args) {
    ParseResult result;
    bool engine_set = false;

    // Connection overrides are collected separately: the defaults depend on
    // which engine was chosen, and --host may appear before --engine.
    std::string host, port, database, user, password;

    for (std::size_t i = 0; i < args.size(); ++i) {
        const std::string& arg = args[i];

        if (arg == "-h" || arg == "--help") {
            result.help = true;
            return result;
        } else if (arg == "--engine") {
            const std::string value = take_value(args, i);
            if (value == "postgres" || value == "postgresql" || value == "pg") {
                result.options.engine = Engine::Postgres;
            } else if (value == "sqlserver" || value == "mssql") {
                result.options.engine = Engine::SqlServer;
            } else {
                throw UsageError("--engine expects postgres or sqlserver, got '" + value + "'");
            }
            engine_set = true;
        } else if (arg == "--legacy") {
            result.options.engine = Engine::SqlServer;
            engine_set = true;
        } else if (arg == "--year") {
            result.options.tax_year = parse_year(take_value(args, i));
        } else if (arg == "--province") {
            result.options.province = take_value(args, i);
        } else if (arg == "--format") {
            const std::string value = take_value(args, i);
            if (value == "text") {
                result.options.format = Format::Text;
            } else if (value == "csv") {
                result.options.format = Format::Csv;
            } else {
                throw UsageError("--format expects text or csv, got '" + value + "'");
            }
        } else if (arg == "--host") {
            host = take_value(args, i);
        } else if (arg == "--port") {
            port = take_value(args, i);
        } else if (arg == "--database") {
            database = take_value(args, i);
        } else if (arg == "--user") {
            user = take_value(args, i);
        } else if (arg == "--password") {
            password = take_value(args, i);
        } else {
            throw UsageError("unknown option '" + arg + "'");
        }
    }

    if (!engine_set) {
        throw UsageError("--engine is required (postgres or sqlserver)");
    }

    result.options.connection = default_connection(result.options.engine);
    if (!host.empty()) result.options.connection.host = host;
    if (!port.empty()) result.options.connection.port = port;
    if (!database.empty()) result.options.connection.database = database;
    if (!user.empty()) result.options.connection.user = user;
    if (!password.empty()) result.options.connection.password = password;

    return result;
}

}  // namespace
}  // namespace t1report

int main(int argc, char** argv) {
    using namespace t1report;

    const std::vector<std::string> args(argv + 1, argv + argc);

    ReportOptions options;
    try {
        ParseResult parsed = parse_arguments(args);
        if (parsed.help) {
            std::cout << kUsage;
            return kExitOk;
        }
        options = std::move(parsed.options);
    } catch (const UsageError& e) {
        std::cerr << "t1report: " << e.what() << "\n\n" << kUsage;
        return kExitUsage;
    }

    std::unique_ptr<IDataSource> source = make_data_source(options.engine);

    try {
        source->connect(options.connection);
    } catch (const ConnectionError& e) {
        std::cerr << "t1report: cannot connect to " << to_string(options.engine) << " at "
                  << options.connection.host << ":" << options.connection.port << "/"
                  << options.connection.database << "\n  " << e.what() << '\n';
        return kExitConnection;
    }

    ReportData data;
    data.source_description = source->describe();
    data.tax_year = options.tax_year;
    data.province_filter = options.province.value_or(std::string{});

    try {
        data.rows = source->fetch_t1_register(options.tax_year, options.province);
    } catch (const QueryError& e) {
        std::cerr << "t1report: query failed against " << to_string(options.engine) << "\n  "
                  << e.what() << '\n';
        return kExitQuery;
    } catch (const std::exception& e) {
        // parse_money throws std::invalid_argument if a driver hands back
        // something that is not a decimal; that is a data problem, not a
        // connection one.
        std::cerr << "t1report: unexpected value from " << to_string(options.engine) << "\n  "
                  << e.what() << '\n';
        return kExitQuery;
    }

    write_report(std::cout, data, options.format);
    return kExitOk;
}
