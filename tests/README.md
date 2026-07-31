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

Mutating tests run inside a rollback scope on both engines, so the fixture is
unchanged and test order never matters. Error-path tests deliberately do **not** —
SQL Server's `XACT_ABORT` discipline means a doomed transaction can neither commit
nor roll back to a savepoint.

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

Three tests fail against the current port. Each is a real defect in
`db/postgres/010_stored_procedures.sql`, found by this suite:

| Test | Defect |
|---|---|
| `RunPayroll_agrees` | The year-to-date subquery is joined with `CROSS JOIN` but references `e` from an earlier `FROM` item — needs `CROSS JOIN LATERAL`. SQL Server used `CROSS APPLY`. |
| `RecalculateAllReturns_agrees` | The `EXCEPTION` handler drops both temp tables before the loop continues, so the next iteration fails on a table that no longer exists. |
| `CloseFiscalYear_agrees` | The nested `CALL acct.usp_postjournalentry(...)` omits the `INOUT p_refcur` argument; PL/pgSQL requires a writable argument and will not fall back to the default. |

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
then return to the 133/3 baseline.

---

## Iterating

`DBPARITY_SKIP_REPLICATION=1` reuses whatever is already loaded instead of
replicating at session start. Useful while working on a single case; unsafe for a
real run, because it removes the row-count gate.
