#pragma once

#include <optional>
#include <stdexcept>
#include <string>

namespace t1report {

enum class Engine { Postgres, SqlServer };

std::string to_string(Engine engine);

struct ConnectionConfig {
    std::string host;
    std::string port;
    std::string database;
    std::string user;
    std::string password;
};

enum class Format { Text, Csv };

struct ReportOptions {
    Engine engine = Engine::Postgres;
    int tax_year = 2024;
    std::optional<std::string> province;
    Format format = Format::Text;
    ConnectionConfig connection;
};

// Thrown when the driver cannot establish a session. Separated from QueryError
// so main can map the two to different exit codes: a harness needs to tell
// "the database is down" from "the schema is wrong".
class ConnectionError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class QueryError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

class UsageError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

}  // namespace t1report
