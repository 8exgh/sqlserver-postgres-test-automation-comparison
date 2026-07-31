# CdnTax.Api — one EF Core model, either engine

An ASP.NET Core Web API over the `CdnTaxPractice` schema, feature-flagged to run
against **SQL Server** or **PostgreSQL** with a single configuration key. Same
binary, same entity model, same endpoints.

```bash
dotnet run --project api/CdnTax.Api --urls http://localhost:5080 --Database:Provider=SqlServer
dotnet run --project api/CdnTax.Api --urls http://localhost:5081 --Database:Provider=Postgres
```

```
$ curl -s localhost:5080/api/health
{"provider":"SqlServer","dataSource":"localhost,11433","database":"CdnTaxPractice","canConnect":true,"clientCount":25}
$ curl -s localhost:5081/api/health
{"provider":"Postgres","dataSource":"tcp://localhost:15432","database":"cdntaxpractice","canConnect":true,"clientCount":25}
```

Every other endpoint returns **byte-identical JSON** on both. `/api/clients`,
`/api/provinces`, `/api/tax-years` and `/api/practitioners` were diffed to confirm it.

---

## Why this exists

`tests/` proves the two schemas agree by running hand-written SQL against both.
`app/` reads from both with hand-written SQL too. Both hide the type-level
differences between the ports, because a human wrote every statement.

An ORM does not. EF Core generates SQL from a model, so **every place the two
schemas diverge in type becomes a mapping decision someone has to make explicitly** —
and the write path forces the issue in a way read-only tooling never does.

This project is that forcing function. All of the divergence lives in one file,
[`Data/CdnTaxContext.cs`](CdnTax.Api/Data/CdnTaxContext.cs), in two methods named
`ApplyPostgresTypes` and `ApplySqlServerTypes` that can be read side by side.

---

## The feature flag

Config key `Database:Provider`, values `SqlServer` (default) or `Postgres`.
Standard ASP.NET Core precedence, so any of these work:

```bash
dotnet run --project api/CdnTax.Api -- --Database:Provider=Postgres   # CLI
Database__Provider=Postgres dotnet run --project api/CdnTax.Api       # environment
```

An unrecognised value is **fatal**, not defaulted. In a project whose entire purpose
is comparing two engines, a typo'd `Database__Provider=postgress` silently serving
SQL Server would be the worst possible outcome.

Connection strings come from `ConnectionStrings:SqlServer` / `ConnectionStrings:Postgres`
if set, and otherwise fall back to `DbParity.Core.TargetConfig` — the same
env-var → repo-root `.env` → docker-compose-default chain the parity suite and the
bash scripts use. If the containers are already running, no configuration is needed.

Set `Database:LogSql=true` to see the SQL each provider emits.

---

## What actually differs between the two engines

The identifier problem solves itself. SQL Server's collation here is
`SQL_Latin1_General_CP1_CI_AS`, so `[client].[clientid]` binds to `ClientId`
case-insensitively; every PostgreSQL object was created unquoted and is already
lowercase. **Naming everything lowercase in the model binds on both** — no name maps,
the same property `app/src/query.cpp` and the parity suite rely on.

Type is where the work is:

| | SQL Server | PostgreSQL | Handling |
|---|---|---|---|
| Booleans | `BIT` | `NUMERIC(1,0)` | `BoolToZeroOneConverter<decimal>` on the port only |
| Concurrency token | `ROWVERSION` (8 bytes, engine-maintained) | `BIGINT` fed by trigger `tr_client_biu` | `NumberToBytesConverter<long>` vs `ValueGeneratedOnAddOrUpdate` |
| Month/sort columns | `TINYINT` | `SMALLINT` | CLR `byte` + `HasConversion<short>()` on the port |
| Timestamps | `DATETIME2(3)` | `timestamp(3) without time zone` | explicit column type; `DateTimeKind.Unspecified` |
| `DisplayName` | `PERSISTED` | `GENERATED ALWAYS … STORED` | read-only on both |
| Identity | `IDENTITY(1,1)` | `GENERATED ALWAYS AS IDENTITY` | `ValueGeneratedOnAdd` |

Three of these are worth expanding on, because they were the ones that bit.

### 1. SQL Server's audit trigger forbids EF's default write strategy

`client.Client` carries `client.tr_Client_Audit`. Since EF Core 7 the SQL Server
provider retrieves generated values with an `OUTPUT` clause, and SQL Server rejects
`OUTPUT` without `INTO` on a table with enabled triggers. Every insert and update
fails until the model declares the trigger:

```csharp
b.ToTable("client", "client", t => t.HasTrigger("tr_Client_Audit"));
```

That switches EF to a post-insert `SELECT`. PostgreSQL needs no equivalent — its
audit triggers are statement-level `AFTER`, and `RETURNING` is unaffected.

### 2. The PostgreSQL rowversion trigger actively rejects being written to

`fn_tr_client_biu` raises if `rowversion` is non-null on `INSERT` or changed on
`UPDATE`. So EF must never put the column in an insert column list or an update `SET`
clause — which is exactly what `ValueGeneratedOnAddOrUpdate()` guarantees, while
`IsConcurrencyToken()` still places the original value in the `WHERE` predicate.

A nice consequence: the token values line up across engines. `NumberToBytesConverter`
is big-endian, the same reading `FixtureReplicator` uses, so client 1 reports
`rowVersion: 2011` on both.

### 3. Trailing-space padding

`CHAR(n)` pads on SQL Server and not on PostgreSQL. `ClientResponse.From` trims the
fixed-length columns, which is what makes the two engines' JSON byte-identical.

---

## A divergence this API is careful *not* to trigger

The port's `ck_client_type` is written `LOWER(clienttype) = LOWER('C') OR …`, so it
accepts `'c'` as well as `'C'`. SQL Server's `CK_Client_Type` accepts both too, via
the case-insensitive collation. **But the computed `DisplayName` column is
case-insensitive on SQL Server and case-sensitive on PostgreSQL** — the port had to
drop `LOWER()` because a generated column needs a resolvable collation
(`db/postgres/003_client_tables.sql:25`).

Insert a corporation with `clienttype = 'c'` and both engines accept the row, then
disagree about what it is:

```
SQL Server   displayname=[Lowercase Widgets Ltd.]     -- corporation branch
PostgreSQL   displayname=[, ]                          -- individual branch
```

No error on either side. This API normalises `clientType` to uppercase before
insert, so it cannot happen through these endpoints — but it is reachable by any
other writer, and it is not in the three bugs `db/README.md` lists.

---

## Endpoints

```
GET    /api/health                       provider, host, database, connectivity, row count
GET    /api/clients                      ?province= &active= &type= &search= &skip= &take=
GET    /api/clients/{id}
POST   /api/clients                      201 + Location
PUT    /api/clients/{id}                 200, or 409 on a stale rowVersion
DELETE /api/clients/{id}                 204
GET    /api/clients/{id}/engagements
GET    /api/practitioners
GET    /api/provinces
GET    /api/tax-years
```

`CdnTax.Api.http` has runnable examples for all of them, including the failure cases.

Validation restates the table's CHECK constraints in
[`Dtos/ClientDtos.cs`](CdnTax.Api/Dtos/ClientDtos.cs) so `CK_Client_TypeShape`
violations come back as a field-level 400 rather than an opaque, engine-specific
driver error. What still reaches the database is translated by
[`Data/DbErrorTranslator.cs`](CdnTax.Api/Data/DbErrorTranslator.cs) — the one place
that has to know both `SqlException.Number` 2627/547 and `PostgresException.SqlState`
23505/23503. That translation table is the honest measure of what the ORM does *not*
abstract away.

---

## ⚠️ Writes desync the parity fixture

`tests/DbParity.sln` compares the two engines row by row and assumes identical seed
data. Anything this API writes — including the `audit.ChangeLog` rows the triggers
add — breaks that assumption.

After write testing, restore:

```bash
# wrote against PostgreSQL only
scripts/replicate-to-postgres.sh

# wrote against SQL Server (it is the source of truth, so it must be rebuilt first)
scripts/reset-sqlserver.sh && scripts/apply-sqlserver.sh
scripts/replicate-to-postgres.sh

dotnet test tests/DbParity.sln
```

Baseline observed after the write testing above was undone: **DbParity.Tests 134
passed / 2 failed, DbParity.Cli.Tests 68 passed / 0 failed.** The two failures are
`ProcedureParityTests.RecalculateAllReturns_agrees` and
`ProcedureParityTests.CloseFiscalYear_agrees` — two of the known PostgreSQL
procedure bugs. No data-comparison test failed, which is the signal that matters
here: the fixture is intact.

(`db/README.md` still quotes an older "133 passed / 3 failed" figure and does not
mention `DbParity.Cli.Tests`. That drift predates this project.)

---

## Build notes

Targets **net10.0 / EF Core 10**, which is forced rather than preferred: EF Core 9's
Npgsql provider wants Npgsql 9.x and would conflict with the Npgsql 10.0.3 that
`DbParity.Core` already references. At the versions pinned in the csproj the graph
unifies with no upgrades — `Npgsql 10.0.3` and `Microsoft.Data.SqlClient 6.1.1`,
exactly what `DbParity.Core` uses.

Kept in its own `api/CdnTax.Api.sln` so `dotnet test tests/DbParity.sln` still builds
only net8.0 projects and an API compile error cannot break the migration test suite.

There are **no EF migrations**. `db/sqlserver/*.sql` and `db/postgres/*.sql` remain
the source of truth; the model maps onto what they already created.
