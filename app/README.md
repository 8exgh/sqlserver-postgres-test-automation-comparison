# t1report — one report, either engine

A small C++20 command-line tool that prints the **T1 assessment register** and
takes a flag choosing whether to read it from the legacy SQL Server or from the
migrated PostgreSQL.

Its purpose is to make the repo's comparison concrete at the application layer.
Run it twice, diff the two outputs, and a byte-identical result is evidence the
migration preserved behaviour — not just that both schemas contain 39 tables.

```
$ t1report --engine postgres --year 2024
CANADIAN TAX PRACTICE - T1 ASSESSMENT REGISTER
Source: PostgreSQL 16.14 (localhost:15432/cdntaxpractice)
Tax year: 2024

CLIENT     NAME                  PR   TAXABLE INCOME        FEDERAL     PROVINCIAL        CREDITS        BALANCE  STATUS
---------------------------------------------------------------------------------------------------------------------------
IND-0001   Chen, Amelia          ON         91150.00       15613.07        6230.94        3196.85       -2752.84  Filed
...
TOTALS (16)                               1399350.00      246862.85      129758.44       55370.63      -20986.34

BY PROVINCE
AB (2)                                     201280.00       35117.04       20128.00        9518.40       -1864.36
...
```

## Build

```bash
scripts/setup-odbc.sh                                  # deps + driver + connectivity check
cmake -S app -B app/build -DCMAKE_BUILD_TYPE=Release
cmake --build app/build
```

`setup-odbc.sh` installs `cmake`, `unixodbc`, `freetds` and `postgresql@14` if
they are missing, registers the FreeTDS driver with unixODBC, and verifies both
databases answer before you build anything. It is idempotent; `--verify` re-runs
only the checks.

## Usage

```
t1report --engine {postgres|sqlserver} [options]

  --engine E        database to read from
  --legacy          shorthand for --engine sqlserver
  --year N          tax year                       (default 2024)
  --province XX     restrict to one province       (default all)
  --format F        text | csv                     (default text)
  --host / --port / --database / --user / --password
  -h, --help
```

Connection details come from the environment first, then from this repo's
`docker-compose.yml`, so `--engine` is normally the only argument you need:

| Engine | Variables | Default |
|---|---|---|
| `postgres` | `PGHOST` `PGPORT` `PGDATABASE` `PGUSER` `PGPASSWORD` | `localhost:15432/cdntaxpractice` as `postgres` |
| `sqlserver` | `MSSQL_HOST` `MSSQL_PORT` `MSSQL_DB` `MSSQL_USER` `MSSQL_SA_PASSWORD` | `localhost:11433/CdnTaxPractice` as `sa` |

Prefer the environment variables over `--password`: anything on the command line
is visible to `ps`.

Exit codes are distinct so a harness can tell the failure modes apart:
`0` success, `2` usage error, `3` connection failure, `4` query failure.

## The cross-engine check

```bash
scripts/run-report.sh                      # 2024, both engines, diff
scripts/run-report.sh --year 2023 --province ON
scripts/run-report.sh --show               # also print the text report
```

```
==> Running the register for 2024
    postgres   16 rows
    sqlserver  16 rows

==> MATCH - both engines produced byte-identical output
    sha256 e4480b952568c8782a70f77c9f4ac1ba4297701d9274f57d7cc9f95faf9e2827
    TOTAL,16,,1399350.00,246862.85,129758.44,55370.63,-20986.34,
```

The script exits non-zero on any difference. That path is not theoretical: it
was tested by adding one cent to a single `federaltax` value in PostgreSQL, and
the diff flagged both the affected row and the grand total.

The CSV deliberately carries **no** engine name, version or endpoint — only
data. Putting the source in it would make every diff fail. The engine identity
lives in the text format's header instead.

## How it is put together

```
include/t1report/            src/
  config.hpp   options, errors  main.cpp             argument parsing, wiring, exit codes
  rows.hpp     T1Row, Totals    query.cpp            the one SQL statement
  datasource.hpp  interface     money.cpp            fixed-point parsing/formatting
  money.hpp    Cents            formatter.cpp        text and CSV writers
  query.hpp    SQL + columns    postgres_source.cpp  libpq
  formatter.hpp                 sqlserver_source.cpp unixODBC
```

**One interface, two backends.** `IDataSource` is all the report knows about a
database. `main` picks an implementation from `--engine`; nothing downstream is
engine-aware, so any difference between the two outputs has to come from the
data rather than from the code that printed it.

**One SQL statement, not two.** The query in `query.cpp` runs *unchanged* on
both engines. That is possible because unquoted identifiers fold
case-insensitively on both, the schema and column names are the same, and the
query avoids every construct where the dialects diverge — no `TOP`/`LIMIT`, no
`ISNULL`, no `+` for concatenation, no date literals.

Two places needed care:

- **Parameter placeholders** are the only dialect difference. They are written
  `{1}`/`{2}` and rewritten to `$1`/`$2` for libpq or `?` for ODBC. Keeping that
  in one visible function beats maintaining two copies of the query that drift.
- **`CAST({2} AS VARCHAR(2))`** around the province parameter. PostgreSQL cannot
  infer a type for a parameter whose only use is `IS NULL` and rejects the
  statement outright; the standard `CAST` gives it one and SQL Server accepts
  the same spelling. A PostgreSQL-style `::varchar` would not have been portable.

Because ODBC placeholders are all bare `?`, the province appears twice in the
statement and must be bound at two positions, where libpq can reference `$2`
repeatedly. That is the single genuine divergence between the two backends.

**Money is integer cents, never `double`.** Both drivers return decimals as
strings. Parsing them to floating point would make the totals depend on rounding,
and a one-cent difference in the last row would be indistinguishable from a real
migration defect — which would quietly destroy the value of the diff.
`money.cpp` parses to `int64_t` cents so the arithmetic is exact.

**SQL Server values are read as characters.** The server has already formatted
the decimals to the column's scale; going through `SQL_C_DOUBLE` would
reintroduce the same rounding problem. `CHAR` columns are also blank-padded, so
the province code arrives as `"ON  "` and is trimmed — without that it would not
match the PostgreSQL output.

## Drivers

PostgreSQL uses **libpq** directly. Homebrew's `postgresql@14` is keg-only and
registers no `.pc` file, so `CMakeLists.txt` asks Homebrew for the prefix and
searches the versioned subdirectories rather than relying on
`find_package(PostgreSQL)`.

SQL Server goes through **unixODBC** with the **FreeTDS** driver, connected
DSN-less so only the driver has to be registered. `TDS_Version=7.4` is what lets
FreeTDS negotiate with SQL Server 2022; it handles the server's required
encryption without extra configuration, so Microsoft's `msodbcsql18` is not
needed.
