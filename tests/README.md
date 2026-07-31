# DbParity — SQL Server ↔ PostgreSQL comparison suite

An xUnit suite that runs **the same assertions against both engines** and fails when
they disagree, so migration defects surface as named test failures.

```bash
scripts/apply-sqlserver.sh          # source of truth
scripts/apply-postgres.sh           # the port
scripts/replicate-to-postgres.sh    # copy sample data across (the suite also does this)
dotnet test tests/DbParity.sln
```

Both containers must be running. Connection settings come from `.env`; any of
`MSSQL_SA_PASSWORD`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` (plus `MSSQL_HOST/PORT`,
`PGHOST/PGPORT`) can be overridden by a real environment variable.

---

## Why one test body can run against both

SQL Server's database collation is `SQL_Latin1_General_CP1_CI_AS`, so identifiers
resolve case-insensitively. Every PostgreSQL object was created unquoted, so it is
lowercase and also resolves case-insensitively. The consequence:

```sql
SELECT ClientId, DisplayName FROM client.Client ORDER BY ClientId
```

binds unchanged on both. `SmokeTests` asserts this premise directly — if either half
of it ever changes, those tests fail first and explain why everything else did.

The exceptions are few and explicit: `CROSS APPLY` vs `LATERAL`, and the catalog
queries. Those cases carry per-engine SQL (see *Case files* below).

---

## Where the data comes from

**SQL Server is the source of truth.** `db/sqlserver/021_seed_sample_data.sql` authors
the sample data; `scripts/replicate-to-postgres.sh` copies the 27 sample tables into
PostgreSQL. There is no PostgreSQL sample seed to drift from it.

Deliberately not copied:

| | Why |
|---|---|
| `ref.*` (12 tables) | Seeded independently on each engine from its own `020_seed_reference_data.sql`, so comparing it stays a real test of the ported seed rather than a tautology. |
| The 18 generated columns | PostgreSQL rejects a written value for a `GENERATED ALWAYS … STORED` column, so it recomputes them — which is how the port's generated expressions get verified. |

One exception is carried across: `021` ends by locking the 2023 tax year
(`UPDATE ref.TaxYear SET IsLocked = 1`), and PostgreSQL never runs that script.
Without the sync, error 50011 could not be raised there at all. *The suite found
this on its first run.*

Because the ported procedures never write the fixture, `ProcedureParityTests` is
what recovers that coverage — it is not optional.

---

## Test families

| File | What it does |
|---|---|
| `SmokeTests` | The shared-SQL premise, and that both engines are reachable. |
| `QueryParityTests` | One `[Theory]` over every `.sql` file in `cases/` — 81 cases. |
| `SchemaPolicyTests` | Asserts the premises the exclusions rest on. |
| `ProcedureParityTests` | All 12 procedures, result sets **and** durable effects. |
| `ErrorCodeParityTests` | All 18 documented `THROW` codes (`SqlException.Number` vs `PostgresException.SqlState`). |
| `CollationSemanticsTests` | Asserts the places the engines genuinely differ. |
| `TriggerConstraintTests` | The 4 triggers and a representative set of constraints. |

Those run in `DbParity.Tests` and talk to the two databases directly. A second
project, **`DbParity.Cli.Tests`** (68 tests), goes one layer up and drives the
compiled C++ tool in `app/` as a black box — the same comparison made through an
actual application:

| File | What it does |
|---|---|
| `CliContractTests` | Argument validation and exit codes. Engine-independent. |
| `EngineFlagTests` | The `--engine` flag itself: one `[Theory]` body, run against both backends. |
| `ReportContentTests` | What the register says, against figures pinned to the shipped fixture. |
| `CrossEngineParityTests` | The headline: the same command against each engine must produce byte-identical CSV. |

`EngineFlagTests` and `ReportContentTests` are `[Theory]`s over both engines
rather than two sets of `[Fact]`s on purpose — if the legacy path and the migrated
path were asserted by separate code, they could drift apart and stop being a
comparison at all.

`CliFixture` builds the binary if it is missing (via `cmake`), then checks that
both databases hold the *same* number of T1 returns before any test runs. Without
that check a fixture that had drifted would fail the parity tests while saying
nothing about the application; instead it fails once, up front, naming
`scripts/replicate-to-postgres.sh`.

These tests are not parallelised: each one starts a child process that connects to
one of the containers, and the emulated SQL Server does not benefit from the load.
The whole CLI suite takes ~22s.

```bash
dotnet test tests/DbParity.Cli.Tests/DbParity.Cli.Tests.csproj   # requires both containers up
```

A third project, **`DbParity.Api.Tests`** (75 tests), does the same for the
ASP.NET Core API in `api/`. `WebApplicationFactory` hosts `CdnTax.Api` twice
in-process — once with `Database:Provider=SqlServer`, once with `Postgres` — and
each test drives it over HTTP. Routing, model binding, EF Core translation, the
database, error classification and JSON serialization are all in the loop; only
Kestrel is not, and that is the one layer that cannot differ between engines.

| File | What it does |
|---|---|
| `ReadEndpointTests` | Health, client list with every filter, paging, get-by-id, engagements, lookups. |
| `WriteEndpointTests` | POST/PUT/DELETE, validation 400s, duplicate 409, FK 400, optimistic-concurrency 409. |
| `CrossEngineParityTests` | The headline: identical requests to each host must return identical JSON. |
| `ApiCollationTests` | Where the API genuinely diverges — asserted, not hidden. See below. |

The flag is set through configuration rather than by swapping the `DbContext`
registration, so the path exercised is the one `Program.cs` actually takes in
production. `Program.cs` gained one line — `public partial class Program;` — because
top-level statements compile to an *internal* `Program` that the test assembly
cannot reach; it changes nothing at runtime.

There is no transaction to roll back here: a request has committed by the time the
response arrives. Instead every created row is registered with a `ClientLifecycle`
and deleted in `DisposeAsync`, pass or fail, under the reserved `APITEST-` code
prefix that `ApiFixture` also sweeps at session start. Verified: 25 clients before
and after, on both engines, across repeated runs. `audit.ChangeLog` rows *are* left
behind — that table is append-only and recording them is the audit trail working,
exactly as `db/README.md` notes for `099_verify.sql`.

**`ApiCollationTests` is the one that matters most.** The `search` parameter passes
the caller's text straight into `EF.Functions.Like`. SQL Server's collation makes
that case-insensitive; PostgreSQL's `LIKE` is not. So `?search=chen` returns matches
today and an empty list after the migration — no error, no warning, and
indistinguishable from "no matches". Both engines are behaving correctly, so no
parity test would ever catch it; only naming the difference does. The `province` and
`type` filters are immune because the endpoint upper-cases them first, which is also
the fix. If someone later applies it, these tests fail and say so.

```bash
dotnet test tests/DbParity.Api.Tests/DbParity.Api.Tests.csproj   # requires both containers up
```

> `CdnTax.Api` and `DbParity.Api.Tests` target **net10.0**; the other two test
> projects stay on net8.0. Building `tests/DbParity.sln` as a whole therefore needs
> the .NET 10 SDK. CI runs each project separately, so the parity and CLI jobs still
> use 8.0.x.

Mutating tests in `DbParity.Tests` run inside a rollback scope on both engines, so
the fixture is unchanged and test order never matters. Error-path tests deliberately
do **not** — SQL Server's `XACT_ABORT` discipline means a doomed transaction can
neither commit nor roll back to a savepoint.

---

## Case files

Cases live on disk as SQL, so adding one touches no C#:

```sql
-- @name      ref.TaxBracket · federal brackets
-- @category  reference-data
-- @table     ref.taxbracket
SELECT * FROM ref.TaxBracket WHERE JurisdictionCode = 'CA' ORDER BY TaxYear, Ordinal;
```

| Directive | Effect |
|---|---|
| `@name` | Display name in the runner |
| `@category` | Grouping |
| `@table` | Applies `policy/excluded-columns.txt` for that table |
| `@exclude` | Extra columns to drop |
| `@json` | Compare these columns as JSON, not text (NVARCHAR vs `jsonb`) |
| `@sort client` | Re-sort both sides ordinally before comparing |
| `@allow-empty` | This case may legitimately return no rows |
| `@divergence-key` | Columns forming the row key for `policy/known-schema-divergences.txt` |

**A case returning zero rows on both sides fails by default.** A vacuously green test
is worse than no test.

Genuinely divergent cases supply `<name>.mssql.sql` and `<name>.pgsql.sql` instead of
`<name>.sql`.

---

## Policy files

Both are deliberately short, and every entry carries its reason.

- **`policy/excluded-columns.txt`** — 4 columns excluded from *value* comparison.
  `client.client.rowversion` (an 8-byte binary counter vs a `bigint`), and the three
  `ref` surrogate identity columns (independently seeded, so the values differ).
  `SchemaPolicyTests` still asserts each exists with the mapped type, that the
  rowversion **ordering** survives the conversion, and — the premise that makes
  replication sound — that **no foreign key targets a `ref` surrogate key**.

- **`policy/known-schema-divergences.txt`** — rows dropped from both sides of a named
  case. Currently two: the `ISJSON(x) = 1` check constraints, which the port replaces
  with the `jsonb` column type. A stale entry is itself a failure
  (`Every_accepted_divergence_still_applies`).

---

## Known failures

All three defects listed here previously were real, and all three are now fixed in
`db/postgres/010_stored_procedures.sql`:

| Test | Defect | Status |
|---|---|---|
| `RunPayroll_agrees` | The year-to-date subquery is joined with `CROSS JOIN` but references `e` from an earlier `FROM` item — needs `CROSS JOIN LATERAL`. SQL Server used `CROSS APPLY`. | **Fixed, passing.** |
| `RecalculateAllReturns_agrees` | The `EXCEPTION` handler drops both temp tables before the loop continues, so the next iteration fails on a table that no longer exists. | Fixed. Still fails — see below. |
| `CloseFiscalYear_agrees` | The nested `CALL acct.usp_postjournalentry(...)` omits the `INOUT p_refcur` argument; PL/pgSQL requires a writable argument and will not fall back to the default. | Fixed. Still fails — see below. |

The handler also captured `var_errMessage` / `var_errNumber` *before* the block it
was reporting on, so each failure was recorded with the previous iteration's
message. That is fixed too: the capture now follows `GET STACKED DIAGNOSTICS`.

### The one remaining divergence: nested result sets

With the errors gone, both surviving failures reduce to a single structural
difference, and it is not a bug in the port:

```
CloseFiscalYear:        sqlserver returned  2 result set(s), postgres returned 1
RecalculateAllReturns:  sqlserver returned 18 result set(s), postgres returned 2
```

On SQL Server a nested procedure's `SELECT` flows all the way out to the client,
so the caller's result sets include the callee's. `usp_RecalculateAllReturns`
therefore emits **one set per return processed** (16 for 2024) plus its own two.

PostgreSQL has no equivalent. A procedure's result sets are its declared `INOUT
refcursor` parameters — a fixed list, fixed at definition time. The callee's
cursor is now passed a writable variable (that is the fix above), but nothing
surfaces it to the client unless the caller re-exports it as its own parameter.

Two ways to close this, both a judgement call rather than a defect fix:

- **`usp_CloseFiscalYear` is reproducible.** Give it a second `INOUT` refcursor,
  pass the first into `usp_PostJournalEntry`, and open its own summary on the
  second. The counts and the order would then match exactly. The cost is baking
  what is arguably incidental SQL Server behaviour into the PostgreSQL signature.
- **`usp_RecalculateAllReturns` is not.** The count is data-dependent — one per
  row processed — and no fixed parameter list can express that. The realistic
  option is to compare only the two summary sets and record the rest as an
  accepted divergence.

Left as-is pending that call, since it changes a public procedure signature.

---

## Proving the suite still detects drift

A green run means nothing until this has been done at least once:

```bash
# 1. a wrong value  -> 12 named failures across reference data, functions, a view and 3 procedures
docker compose exec -T postgres psql -U postgres -d cdntaxpractice \
  -c "UPDATE ref.taxbracket SET rate = rate + 0.01 WHERE taxyear=2024 AND jurisdictioncode='CA' AND ordinal=1;"

# 2. a schema change -> schema/columns fails
docker compose exec -T postgres psql -U postgres -d cdntaxpractice \
  -c "ALTER TABLE tax.t1return ALTER COLUMN provinceofresidence DROP NOT NULL;"

# 3. a missing row   -> tables/acct.journalline fails on row count
docker compose exec -T postgres psql -U postgres -d cdntaxpractice \
  -c "SET session_replication_role=replica; DELETE FROM acct.journalline WHERE journallineid = (SELECT MIN(journallineid) FROM acct.journalline);"
```

Undo 1 and 2 by hand (they are outside the replicated set); 3 is repaired by
re-running `scripts/replicate-to-postgres.sh`. All three were verified to fail and
then return to the 134/2 baseline.

The CLI suite was proved the same way — a one-cent divergence on a single row:

```bash
docker compose exec -T postgres psql -U postgres -d cdntaxpractice -c \
  "UPDATE tax.t1return SET federaltax = federaltax + 0.01
   WHERE taxyear = 2024
     AND clientid = (SELECT clientid FROM client.client WHERE clientcode = 'IND-0001');"
```

That fails exactly six of the 68 and no others: all five `CrossEngineParityTests`
covering 2024 and `ON`, plus `Year_2024_matches_the_shipped_fixture` on the
**postgres** side only. 2023 and 2025 parity stay green, which is what confirms
the failure is scoped to the row that was touched rather than a blanket
comparison failing. Subtracting the cent restores all 68.

---

## Iterating

`DBPARITY_SKIP_REPLICATION=1` reuses whatever is already loaded instead of
replicating at session start. Useful while working on a single case; unsafe for a
real run, because it removes the row-count gate.
