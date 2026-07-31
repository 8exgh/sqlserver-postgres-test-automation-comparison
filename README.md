#  By Sean Bennett

[![tests](https://github.com/8exgh/sqlserver-postgres-test-automation-comparison/actions/workflows/tests.yml/badge.svg)](https://github.com/8exgh/sqlserver-postgres-test-automation-comparison/actions/workflows/tests.yml)

# Proof of concept: AWS Schema Conversion Tool + Automated Comparison Testing

## Scope is Sql Server -> AWS Schema Conversion Tool -> Postgres -> Automate testing (comparison)

# Domain is Canadian Tax & Accounting — SQL Server schema

A SQL Server 2022 schema for a Canadian accounting practice: personal (T1) and
corporate (T2) returns, information slips, GST/HST filings, double-entry
bookkeeping, payroll with CPP/EI, and an audit trail.

---

## What this repository demonstrates

1) Migrating and testing Sql Server -> Postgres via AWS Schema Conversion Tool (command line)and custom tests
2) Proof of concept C++ report feature flagged to both sql server + postgres
3) Proof of concept C# web api feature flagged to both sql server + postgres
4) Running the DbParity automated tests in Github CI/CD

# Walkthrough of the problems found

```
  SQL Server 2022
  39 tables · 9 views · 20 functions · 12 procedures · 4 triggers · 57 FKs
            │
            ▼
  AWS Schema Conversion Tool  (to Postgres)
            │
            ▼
  Errors found
  · MERGE not translated at all
  · 2 views emitted as (text, error_msg) stubs — PIVOT and OPENJSON
  · apply landed 38/39 tables and 40/57 FKs; client.Client rejected outright
            │
            ▼
  Manual repair  (db/postgres/*.sql)
  MERGE, OPENJSON, PIVOT, dynamic SQL, TVPs and DELETE TOP rewritten by hand
  → 099_verify.sql green: 39 tables · 9 views · 20 functions · 12 procedures
            │
            ▼
  Differential test suite  (tests/DbParity.sln)
  136 xUnit tests · 81 data-driven SQL cases · one test body, both engines
            │
            ▼
  3 bugs found in the hand-repaired port between Sql Server + Postgres
            │
            ▼
```

Comparing the Sql Server / Postgres with DbParity tests was important because the Schema Conversion Tool does not say what translated incorrectly.

The three bugs DbParity tests found:

usp_RunPayroll -> The year-to-date subquery uses CROSS JOIN but references an alias from an earlier FROM item; needs CROSS JOIN LATERAL. The T-SQL original used CROSS APPLY.

usp_RecalculateAllReturns -> The EXCEPTION handler drops both temp tables before the loop continues, so the next iteration hits a table that no longer exists.

usp_CloseFiscalYear -> The nested CALL usp_PostJournalEntry(...) omits the INOUT refcursor argument; PL/pgSQL requires a writable argument and will not fall back to the default.

### The three bugs

All in `db/postgres/010_stored_procedures.sql`, all invisible until executed:

| Procedure | Defect |
|---|---|
| `usp_RunPayroll` | The year-to-date subquery uses `CROSS JOIN` but references an alias from an earlier `FROM` item — needs `CROSS JOIN LATERAL`. The T-SQL original used `CROSS APPLY`. |
| `usp_RecalculateAllReturns` | The `EXCEPTION` handler drops both temp tables before the loop continues, so the next iteration hits a table that no longer exists. |
| `usp_CloseFiscalYear` | The nested `CALL usp_PostJournalEntry(...)` omits the `INOUT` refcursor argument; PL/pgSQL requires a writable argument and will not fall back to the default. |

Two further findings that neither the tool nor a review would produce:

- **The 2023 tax year was never locked on PostgreSQL.** `021_seed_sample_data.sql`
  locks it at the very end of the *sample* seed, and PostgreSQL only ever runs the
  *reference* seed — so error 50011 could not be raised there at all.
- **Audit payloads diverge for every row written after cutover.** SQL Server's
  `FOR JSON` emits `"ClientCode"` and `"IsActive":true`; the port emits
  `"clientcode"` and `"isactive":1`. Historical rows are identical, so only a
  behavioural test catches it.

See [`tests/README.md`](tests/README.md) for how to run the suite, and
[Converting to PostgreSQL with AWS SCT](#converting-to-postgresql-with-aws-sct)
below for the conversion detail.

---

## About the fixture

The SQL Server schema exists to be a **fixture** — something a test-automation
harness can be pointed at, and something that could be ported to PostgreSQL for a
side-by-side comparison. Two consequences follow from that, and they shape almost
every decision below:

- **It is deterministic.** No `NEWID()`, `RAND()`, or `GETDATE()` in any stored
  value. `tax.fn_FederalTax(2024, 100000)` returns `17427.32` today and next
  year. Assertions can be written against exact values.
- **It is portable-minded.** Every T-SQL feature used has a known PostgreSQL
  analogue, mapped at the bottom of this file.

---

## ⚠️ Accuracy notice

The tax brackets, CPP/EI limits, credit amounts and sales-tax rates seeded in
`020_seed_reference_data.sql` come from published CRA and provincial figures for
2023–2025 and are here so the calculations behave realistically under test.

**They are fixture data, not a tax engine.** They have not been verified against
every mid-year amendment, surtax, or provincial levy, and several deliberate
simplifications are listed under [Known simplifications](#known-simplifications).
Do not rely on any figure here for an actual filing.

---

## Quick start

```bash
cp .env.example .env          # optional; a default password is built in
scripts/apply-sqlserver.sh    # boots SQL Server, applies everything, verifies
```

Then connect from DataGrip / Azure Data Studio / sqlcmd:

| | |
|---|---|
| Server | `localhost,11433` |
| User | `sa` |
| Password | `Str0ng!Passw0rd` (or your `.env` value) |
| Database | `CdnTaxPractice` |

Other entry points:

```bash
scripts/apply-sqlserver.sh --skip-seed   # schema + programmability only
scripts/apply-sqlserver.sh --no-verify   # skip the acceptance gate
scripts/reset-sqlserver.sh               # drop the database, rebuild, verify
scripts/reset-sqlserver.sh --hard        # also destroy the container volume
```

`sqlcmd` runs **inside** the container, so nothing needs installing on the host.

> **Apple Silicon.** The `mssql/server:2022-latest` image is amd64-only and runs
> under Docker Desktop's emulation. It works, but the first boot takes a couple
> of minutes — the apply script waits up to 300s.

---

## Object inventory

| Kind | Count | Notes |
|---|---:|---|
| Tables | 39 | across 6 domain schemas |
| Views | 9 | one of them indexed (materialized) |
| Scalar functions | 15 | |
| Inline table-valued functions | 3 | |
| Multi-statement table-valued functions | 2 | |
| Stored procedures | 12 | |
| Triggers | 4 | including one `INSTEAD OF` on a view |
| Sequences | 1 | |
| User-defined table types | 3 | used as table-valued parameters |
| Synonyms | 1 | |
| Filtered indexes | 10 | |
| Computed columns | 18 | all persisted |

`099_verify.sql` asserts every one of these counts, so an object that silently
fails to compile is caught rather than shipped.

### Schemas

| Schema | Holds | Tables |
|---|---|---:|
| `ref` | Rates, brackets, provinces, slip definitions, holidays | 12 |
| `client` | Clients, addresses, contacts, engagements, practitioners | 5 |
| `tax` | T1/T2 returns, slips, GST/HST, instalments, assessments | 9 |
| `acct` | Fiscal years, chart of accounts, journals, invoices | 7 |
| `payroll` | Employees, pay periods, paystubs, remittances | 4 |
| `audit` | Change log, return status history | 2 |
| `util` | Cross-cutting helpers (Luhn, business days) | — |

### Functions

| Kind | Object | What it does |
|---|---|---|
| Scalar | `util.fn_PassesLuhn` | Mod-10 check, doubling from the right |
| Scalar | `tax.fn_IsValidSIN` | Nine digits + Luhn check digit |
| Scalar | `tax.fn_IsValidBusinessNumber` | Bare BN or full `123456789RT0001` form |
| Scalar | `tax.fn_BracketTax` | Progressive tax for any jurisdiction |
| Scalar | `tax.fn_FederalTax` | Wrapper over `fn_BracketTax` for `'CA'` |
| Scalar | `tax.fn_ProvincialTax` | Wrapper for a province code |
| Scalar | `tax.fn_MarginalRate` | Combined federal + provincial marginal rate |
| Scalar | `tax.fn_CPPContribution` | Base tier, exemption and YMPE cap |
| Scalar | `tax.fn_CPP2Contribution` | Second tier between YMPE and YAMPE |
| Scalar | `tax.fn_EIPremium` | MIE cap, separate Quebec rate |
| Scalar | `ref.fn_GSTHSTRate` | Federal portion, date-ranged |
| Scalar | `ref.fn_PSTRate` | Provincial portion (PST/QST) |
| Scalar | `ref.fn_SalesTaxRate` | The two combined |
| Scalar | `acct.fn_AccountBalance` | Signed by the account's normal balance |
| Scalar | `util.fn_BusinessDaysBetween` | Weekends + statutory holidays |
| Inline TVF | `tax.fn_TaxBracketBreakdown` | Per-bracket income, tax, running total |
| Inline TVF | `tax.fn_ClientSlipTotals` | Slip boxes rolled into T1 income lines |
| Inline TVF | `acct.fn_InvoiceAging` | Outstanding receivables, bucketed |
| MSTVF | `acct.fn_TrialBalance` | Per-account totals plus a total row |
| MSTVF | `acct.fn_AccountHierarchy` | Recursive CTE with depth and path |

### Views

| Object | Of note |
|---|---|
| `client.vw_ClientDirectory` | Target of an `INSTEAD OF INSERT` trigger |
| `tax.vw_T1ReturnSummary` | Assessed figures vs. a live recalculation |
| `tax.vw_OutstandingGSTHST` | Unfiled or still owing |
| `acct.vw_InvoiceAging` | Built with `PIVOT` |
| `acct.vw_GeneralLedger` | Running balance via `SUM() OVER` |
| `acct.vw_FiscalYearRevenue` | **Indexed view** — `SCHEMABINDING` + `COUNT_BIG` |
| `payroll.vw_YearToDatePayroll` | Year-to-date window sums per employee |
| `tax.vw_ClientTaxProfile` | Widest cross-schema roll-up |
| `audit.vw_RecentChanges` | `OPENJSON` shredding of the audit payloads |

### Stored procedures

| Object | Exercises |
|---|---|
| `client.usp_UpsertClient` | `MERGE`, `OUTPUT $action`, validation, `THROW` |
| `client.usp_SearchClients` | Parameterized dynamic SQL via `sp_executesql` |
| `tax.usp_CalculateT1` | Transaction + immutable assessment history |
| `tax.usp_RecalculateAllReturns` | Batch driver that reports failures, not exceptions |
| `tax.usp_ImportSlips` | `OPENJSON ... WITH`, nested arrays, `MERGE` |
| `tax.usp_FileGSTHSTReturn` | Derives GST34 lines from the ledger |
| `tax.usp_GenerateClientYearEndPackage` | Five result sets in one call |
| `acct.usp_PostJournalEntry` | Table-valued parameter, savepoint, balance check |
| `acct.usp_GenerateInvoice` | Sequence, province-aware tax, `OUTPUT` clause |
| `acct.usp_CloseFiscalYear` | Explicit cursor, nested procedure call |
| `payroll.usp_RunPayroll` | Set-based `CROSS APPLY` over the CPP/EI functions |
| `audit.usp_PurgeChangeLog` | Batched `DELETE TOP (n)` loop |

### Triggers

| Object | Timing | Purpose |
|---|---|---|
| `acct.tr_JournalLine_NoPostedEdits` | `AFTER UPDATE, DELETE` | Posted books are immutable |
| `client.tr_Client_Audit` | `AFTER INSERT, UPDATE, DELETE` | JSON before/after images |
| `tax.tr_T1Return_StatusHistory` | `AFTER UPDATE` | Filing status transitions |
| `client.tr_ClientDirectory_Insert` | `INSTEAD OF INSERT` | Makes a 3-table view insertable |

---

## Design notes

A few decisions that are load-bearing and non-obvious.

**Computed columns are one level deep.** Every computed column is expressed over
*stored* columns only, never over another computed column. SQL Server permits
the chained form; PostgreSQL generated columns do not. Keeping to one level
makes the port mechanical.

**Assessed facts are stored, not computed.** `TotalPayable` and `BalanceOwing`
on `tax.T1Return` are written by `tax.usp_CalculateT1` rather than derived,
because an assessment is a historical fact. `tax.vw_T1ReturnSummary` recomputes
them live and exposes the variance — which is precisely the condition
`usp_RecalculateAllReturns` exists to clear.

**`XACT_ABORT` is scoped to the write, not the procedure.** With `XACT_ABORT ON`
for a whole procedure body, a *validation* `THROW` — raised before anything is
written — dooms the caller's transaction, so the caller's next write fails with
error 3930 and a batch driver cannot record the failure and carry on. The
pattern used instead is: validate, then `SET XACT_ABORT ON`, then transact.
`acct.usp_PostJournalEntry` and `acct.usp_CloseFiscalYear` never set it at all,
because a doomed transaction cannot be rolled back to a savepoint, which would
defeat their nested-call design.

**Database-level `ARITHABORT ON`.** The indexed view imposes a session-option
contract: any connection writing to its base tables needs `ARITHABORT ON` and
`NUMERIC_ROUNDABORT OFF`, or the `INSERT` is rejected outright. ODBC and .NET
drivers leave `ARITHABORT` off, so `001` sets it as a database default and test
harnesses inherit it without having to remember.

**Weekday arithmetic avoids `DATEPART(WEEKDAY, …)`**, which depends on the
session's `SET DATEFIRST` and would give different callers different answers.
`util.fn_BusinessDaysBetween` counts from a known Monday instead.

**Cascade paths are single-headed.** `client.Client` cascades to fiscal years,
accounts, journal entries and invoices; every other foreign key is `NO ACTION`,
so no table has two cascade paths into it. Deleting an account that carries
postings fails loudly, by design.

---

## Idempotency

The whole apply is re-runnable and converges on the same state:

- tables and indexes — `IF OBJECT_ID(...) IS NULL CREATE ...` (non-destructive)
- programmability — `CREATE OR ALTER`
- reference data — `MERGE`
- sample data — guarded on whether any client exists; a second run is a no-op

Verified: three consecutive applies all pass verification, and every table
returns to an identical row count.

**One deliberate exception.** `audit.ChangeLog` is append-only and permanently
records the eight scratch operations that `099_verify.sql` performs on its own
test clients. That is the audit log working correctly, not drift.

`008_functions.sql` opens with explicit `DROP FUNCTION` statements rather than
relying on `CREATE OR ALTER` alone. Three of its functions are called by other
`WITH SCHEMABINDING` functions, and schema binding is exactly the promise that a
callee will not change under its caller — so `ALTER` on the callee fails with
error 3729 while the caller exists. Dependents must be dropped first.

---

## Error codes

`THROW` numbers are stable so a harness can assert on them instead of on message
text.

| Code | Raised when |
|---:|---|
| 50001 | Journal entry does not balance |
| 50002 | Unknown account number on a journal line |
| 50003 | Posting attempted to a control account |
| 50004 | Fiscal year is closed |
| 50005 | Entry date outside its fiscal year |
| 50006 | Journal entry has no lines |
| 50007 | Attempt to modify a line of a posted entry |
| 50008 | Client-directory insert missing a required field |
| 50010 | T1 return not found |
| 50011 | Tax year is locked |
| 50020 | Malformed slip JSON |
| 50021 | Unknown client |
| 50030 | Overlapping GST/HST period |
| 50040 | Invalid SIN |
| 50041 | Invalid business number |
| 50042 | Client type / field mismatch |
| 50050 | Invoice has no lines |
| 50060 | Pay period already processed |
| 50999 | Verification failed (`099_verify.sql`) |

---

## Seed data

Deterministic and fixed. All SINs and Business Numbers are synthetic values that
satisfy the mod-10 check digit — they are not real identifiers belonging to
anyone.

| | |
|---|---:|
| Clients (16 individuals, 9 corporations) | 25 |
| T1 returns (2023–2025) | 42 |
| T2 returns | 9 |
| Information slips / boxes | 49 / 175 |
| Chart-of-accounts rows | 63 |
| Journal entries / lines | 112 / 337 |
| Invoices / lines / payments | 47 / 70 / 20 |
| Paystubs | 190 |
| GST/HST returns | 12 |

Where a procedure exists to create something, the seed calls it rather than
inserting directly — so loading the fixture also exercises `usp_ImportSlips`,
`usp_PostJournalEntry`, `usp_GenerateInvoice`, `usp_FileGSTHSTReturn`,
`usp_RunPayroll`, `usp_CalculateT1` and `usp_CloseFiscalYear`.

Two states are seeded on purpose so their error paths have real data to hit:
the **2023 tax year is locked** (error 50011), and **one fiscal year is closed**
(error 50004).

### Bracket coverage

Deliberately uneven, and asserted as such:

| Jurisdiction | Years |
|---|---|
| Federal (`CA`) | 2023, 2024, 2025 |
| ON, BC, AB, QC | 2023, 2024, 2025 |
| All other provinces/territories | 2024 only |

Seeded T1 returns respect this: clients resident in the other provinces have
2024 returns only.

---

## Known simplifications

Stated plainly rather than buried, because a fixture that quietly lies is worse
than one with documented edges.

- **CPP per-period split.** `tax.fn_CPPContribution` uses the *annual* formula.
  Real payroll prorates the basic exemption across pay periods; applying the
  annual formula to cumulative earnings absorbs the whole exemption in the first
  period. The annual total for a full year is identical — the period-by-period
  split is not.
- **Withholding is an estimate.** `payroll.usp_RunPayroll` annualizes salary,
  taxes the amount above the TD1 claim and divides back down. It does not
  implement the CRA's T4127 payroll formulas.
- **2025 federal lowest rate** is seeded as 14.5%, the full-year effective rate
  produced by the mid-2025 drop from 15% to 14%.
- **Credits are simplified** to the basic personal amount and Canada employment
  amount, claimed at the jurisdiction's lowest bracket rate. No spousal
  transfers, no clawbacks, no high-income BPA reduction.
- **No surtaxes or provincial levies** (Ontario surtax, health premiums, etc.).
- **`acct.vw_InvoiceAging` and `tax.vw_ClientTaxProfile` are "as at today"** and
  so are not deterministic. Assertions against them must be structural, not
  value-based; `099_verify.sql` treats them accordingly.
- **Posted books cannot be deleted.** Because cascading deletes fire
  `acct.tr_JournalLine_NoPostedEdits`, a client carrying posted journal entries
  cannot be deleted at all. That is the intended reading of "the books are
  immutable", but it does surprise people.

---

---

## Converting to PostgreSQL with AWS SCT

`scripts/convert-to-postgres.sh` drives `lib/AWSSchemaConversionToolBatch.jar`
(AWS Schema Conversion Tool, build 677) against the running SQL Server and
produces PostgreSQL DDL, an assessment report, and optionally creates the
objects in the `postgres` service from `docker-compose.yml`.

```bash
scripts/convert-to-postgres.sh                  # convert + report, writes nothing to PG
scripts/convert-to-postgres.sh --apply          # also create the objects in PostgreSQL
scripts/convert-to-postgres.sh --report-only    # assessment report only
scripts/convert-to-postgres.sh --bootstrap-jvm  # fetch the x86_64 JDK it needs (see below)
scripts/convert-to-postgres.sh --keep-scenario  # leave the generated .scts for inspection
```

| Output | Where |
|---|---|
| Converted DDL | `db/postgres/generated/cdntaxpractice-postgresql.sql` |
| Assessment report (CSV + PDF) | `build/sct/report/` |
| SCT project (openable in the desktop app) | `build/sct/project/` |
| SCT log | `build/sct/log/sct-run.log` |

The script generates its own SCT scenario each run, so the connection details
live in one place. It waits for both databases, downloads the JDBC drivers, and
verifies it actually produced DDL rather than trusting SCT's exit code — SCT
exits 0 even when a command quietly wrote nothing.

### Four things that will waste your afternoon

Each of these fails in a way that does not name the real cause. All four are
handled by the script; they are written down because the error messages are
actively misleading.

1. **The jar will not start.** `java -jar` reports only *"An unexpected error
   occurred while trying to open file"*. The jar is signed and its
   `META-INF/SIGNER.SF` is ~31 MB, over the 8 MB cap that JDK 17.0.7+ enforces.
   Fix: `-Djdk.jar.maxSignatureFileSize=100000000`.

2. **It needs an x86_64 JVM on macOS.** SCT initialises a JavaFX toolkit even in
   CLI mode and routes every converted object through it, but the macOS JavaFX
   natives inside the jar (`libglass.dylib` and friends) are x86_64-only. On an
   arm64 JVM every object fails with *"No toolkit found"* and the conversion
   writes an empty file **while still exiting 0**. The script refuses to run on
   an arm64 JVM; `--bootstrap-jvm` fetches Amazon Corretto 17 x64 into
   `build/jvm/`, which runs fine under Rosetta. (SCT also rejects non-Corretto
   JREs by vendor name, which is a warning rather than a stop.)

3. **Java 17 module access.** Without `--add-opens java.base/java.lang.reflect`
   (and a few siblings) the T-SQL parser dies partway with a `PARSER ERROR`
   about `java.base` not opening `java.lang.reflect`.

4. **Tree paths are dot-separated, and the two sides have different shapes.**
   A path built with `/` resolves to nothing and surfaces only as an
   `ArrayIndexOutOfBoundsException` from inside the tool. The first segment is a
   throwaway label that the resolver strips before treating the next one as the
   server name. SQL Server nests schemas under a database; PostgreSQL has no
   `Databases` level at all:

   ```
   source   Servers.MSSQL.Databases.CdnTaxPractice.Schemas.<schema>
   target   Servers.POSTGRESQL.Schemas.<schema>
   ```

   The schema mapping itself is made one level up, database → server
   (`Servers.MSSQL.Databases.CdnTaxPractice` → `Servers.POSTGRESQL`). Mapping
   the wildcarded schema paths to each other is rejected, because the target
   schemas do not exist yet and the wildcard has nothing to match.

The scenario grammar is worth knowing too: commands are terminated by `/` on its
own line (**not** `;`), arguments are `-name: 'value'`, and `#` starts a comment.

### What the conversion actually produced

Every object type in the schema was converted, matching the source counts:

| | Source | Converted |
|---|---:|---:|
| Schemas | 7 (+dbo) | 8 |
| Tables | 39 | 39 |
| Views | 9 | 9 (2 as error stubs) |
| Functions | 20 | 20 (+7 extension-pack helpers) |
| Procedures | 12 | 12 |
| Triggers | 4 | 4 (+3 generated) |
| Sequences | 1 | 1 |
| Foreign keys | 57 | 57 |

### Known conversion gaps

The script reports these; they are properties of the schema and of SCT, not of
the script.

- **`MERGE` is not translated.** SCT cannot render T-SQL `MERGE` into
  PostgreSQL, so the procedures built on it (`usp_UpsertClient`,
  `usp_ImportSlips`, `usp_RunPayroll`) come out incomplete. Ironic given that
  PostgreSQL 15+ *does* have `MERGE` — this is a tool limitation.
- **Two views could not be converted at all** and are emitted as stubs whose
  only columns are `(text, error_msg)`: `vw_invoiceaging` (uses `PIVOT`) and
  `vw_recentchanges` (uses `OPENJSON`).
- **`--apply` leaves the target incomplete.** One table, `client.client`, is
  rejected by PostgreSQL:

  ```
  ERROR: could not determine which collation to use for lower() function
  ```

  SCT emulates SQL Server's case-insensitive collation by wrapping comparisons
  in `LOWER()`, and it does so inside the generated column that replaces the
  persisted computed `DisplayName`. PostgreSQL requires a deterministic
  collation in a generated-column expression and refuses. The 74 foreign keys
  that reference `client.client` then fail as a consequence, so 38 of 39 tables
  and 40 of 57 foreign keys land.

  The generated expression is:

  ```sql
  displayname VARCHAR(150) NOT NULL GENERATED ALWAYS AS (CASE
      WHEN LOWER(clienttype) = LOWER('C') THEN COALESCE(legalname, '')
      ELSE CONCAT(COALESCE(lastname, ''), ', ', COALESCE(firstname, ''))
  END) STORED
  ```

  Dropping both `LOWER()` calls is safe here — `CK_Client_Type` already
  restricts `ClientType` to `'I'` or `'C'` — after which the file applies
  cleanly with `psql`. That edit is left to you rather than being patched in
  automatically, since it is a porting decision about the schema.

---

---

## The PostgreSQL port (`db/postgres/`)

`db/postgres/` is a hand-finished PostgreSQL schema that applies cleanly and
behaves like the SQL Server source. It was bootstrapped from the AWS SCT output
in `db/postgres/generated/` and then corrected object by object.

```bash
scripts/apply-postgres.sh              # apply everything, then verify
scripts/apply-postgres.sh --only 008   # apply one numbered file
scripts/reset-postgres.sh              # drop the schemas, rebuild, verify
scripts/reset-postgres.sh --hard       # also destroy the container volume
```

Connect on `localhost:15432`, database `cdntaxpractice`. The file numbering
mirrors `db/sqlserver/` so the two sides read side by side, and the schemas keep
their bare names (`ref`, `client`, `tax`, `acct`, `payroll`, `audit`, `util`)
rather than SCT's `cdntaxpractice_*`, so one set of object names works against
both engines.

**Scope.** Schema, programmability and reference data (`020`). The sample data
(`021`) is not ported; `db/postgres/099_verify.sql` therefore creates and
removes its own scratch fixture.

### Verified parity

Both `099_verify.sql` scripts pass. The PostgreSQL one asserts the same values
as the SQL Server one — `fn_FederalTax(2024, 100000) = 17427.32`,
`fn_CPPContribution(2024, 100000) = 3867.50`, EI 1049.12 / 834.24 (QC),
NS HST 15% before 2025-04-01 and 14% after, the Luhn SIN pair, business days
across the 2024 holidays — plus the error contracts, asserted by SQLSTATE.

| | SQL Server | PostgreSQL |
|---|---:|---:|
| Tables | 39 | 39 |
| Computed / generated columns | 18 | 18 |
| Views | 9 (1 indexed) | 9 (1 materialized) |
| Functions | 20 | 20 |
| Procedures | 12 | 12 |
| Triggers | 4 | 8 |
| Foreign keys | 57 | 57 |
| Unique constraints | 24 | 24 |
| Filtered / partial indexes | 10 | 10 |

Triggers go from 4 to 8 because PostgreSQL needs one trigger per operation when
transition tables are used (`OLD TABLE` only exists for UPDATE/DELETE), plus one
with no SQL Server counterpart that emulates `ROWVERSION`.

A clean rebuild followed by two repeat applies all pass: every file is
re-runnable (`CREATE ... IF NOT EXISTS`, catalog-guarded constraints,
`MERGE`-based seeds).

### What AWS SCT got wrong

Everything below was found by applying the output and reading the actual error,
not by inspection. The three in bold are the dangerous ones: SCT reported
success and the object counts still matched.

- **Five computed columns silently gutted.** `invoiceline.linetotal`,
  `t1return.{taxableincome, netfederaltax, netprovincialtax}` and
  `t2return.taxableincome`. Action item 7811 says it "skips the unsupported
  CONVERT function" — in fact it drops the whole `GENERATED` expression and
  leaves the column as a plain `NOT NULL` with no default, so any insert that
  omits it fails and the value is never computed. `scripts/convert-to-postgres.sh`
  now fails the run when the generated-column count is short of the source.
- **The `INSTEAD OF INSERT` trigger on `vw_ClientDirectory` vanished.** No
  trigger on that view exists anywhere in the generated file, and nothing in the
  report says one was dropped.
- **`SET @PostedBy = ISNULL(@PostedBy, SUSER_SNAME())` dropped** from
  `usp_PostJournalEntry`, leaving `PostedBy` NULL and violating
  `ck_journalentry_posted` on every post.
- `client.client` could not be created at all: SCT emulated SQL Server's
  case-insensitive collation with `LOWER()` inside the generated column
  replacing `DisplayName`, which PostgreSQL rejects for want of a resolvable
  collation. That took 74 dependent foreign keys with it.
- `MERGE` not translated in three procedures (action item 9996), leaving bodies
  that silently did nothing. PostgreSQL 15+ has `MERGE`; all three are restored.
- `OPENJSON`, `ISJSON`, `PIVOT`, `DELETE TOP (n)` and `sp_executesql` all left
  as commented-out T-SQL. Two views were emitted as `(text, error_msg)` stubs.
- The indexed view was flattened to a plain view, silently losing its
  materialization.
- **Wrong casts.** `tax.fn_IsValidSIN` called `fn_PassesLuhn(par_SIN::NUMERIC(18,0))`
  — a function taking VARCHAR, so the call did not resolve, and the numeric
  conversion would have stripped the leading zero from a SIN like `046454286`
  and broken the check digit. Same cast on the business number.
- **`SELECT @var = expr FROM ...` rendered as `STRING_AGG(col1, '')`** in the two
  sales-tax rate functions, with the `INTO` nested uselessly inside a subquery.
  Neither compiled.
- **`DECLARE ... DEFAULT` used for assignments that must run later.** T-SQL
  evaluates `DECLARE @x = expr` where it is written; PL/pgSQL evaluates a
  `DECLARE` default on block entry. SCT hoisted eleven of these above the
  `SELECT`s they depend on, so they computed from NULLs — silently returning
  NULL from `fn_CPPContribution`, ignoring the EI maximum, and inserting NULL
  tax amounts on invoices.
- `OUTER APPLY` rendered as a bare `CROSS JOIN`, which neither parses without
  `LATERAL` nor preserves the outer row.
- BIT columns became `NUMERIC(1,0)` but were still used as booleans
  (`CASE WHEN fy.isclosed THEN`).
- Multi-statement table functions staged through temp tables, and every
  `RETURNING` value staged through one too — the latter leaving a cursor open
  over a table the next call then could not drop.
- Everything depended on the `aws_sqlserver_ext` extension pack for `datediff`,
  `conv_string_to_date` and `tomsbit`; all sixteen call sites are now native.

### Deliberate differences from the source

- **The materialized view is not maintained automatically.** SQL Server updates
  an indexed view on every write; `REFRESH MATERIALIZED VIEW` is explicit.
- **`displayname` is case-sensitive.** The `LOWER()` wrappers are kept
  everywhere except inside that generated column, where they are what broke it.
  `ck_client_type` already restricts the value to `'I'` or `'C'`.
- **No synonym.** PostgreSQL has none; `dbo.Clients` is dropped.
- **`SMALLINT` parameters widened to `INTEGER`.** PostgreSQL will not implicitly
  narrow an integer literal during function resolution, so
  `tax.fn_FederalTax(2024, 100000)` would not have resolved at all.
- **Procedures return `INOUT refcursor`.** The caller must pass a cursor
  variable and reset it between calls.
- **`audit.changelog.oldvalues/newvalues` are `jsonb`**, which enforces validity
  by type and makes the two `ISJSON` CHECK constraints redundant — hence 76
  CHECK constraints against SQL Server's 78.

---

## T-SQL → PostgreSQL feature map

Written now, while the reasoning is fresh, so the eventual port is a translation
exercise rather than a redesign. **No PostgreSQL code exists yet** — this is a
specification, not an implementation.

| T-SQL | PostgreSQL | Notes |
|---|---|---|
| `IDENTITY(1,1)` | `GENERATED ALWAYS AS IDENTITY` | |
| `SEQUENCE` / `NEXT VALUE FOR` | `SEQUENCE` / `nextval()` | Near-identical |
| Computed column `AS (…) PERSISTED` | `GENERATED ALWAYS AS (…) STORED` | PG cannot reference other generated columns — already avoided here |
| `ROWVERSION` | `xmin` system column, or a trigger-maintained `bigint` | No direct equivalent |
| Filtered index `WHERE …` | Partial index `WHERE …` | PG's predicates are strictly more capable |
| Covering index `INCLUDE (…)` | `INCLUDE (…)` | PG 11+ |
| Indexed view | `MATERIALIZED VIEW` + `REFRESH` | PG does not auto-maintain; refresh becomes explicit |
| `SCHEMABINDING` | No equivalent | PG dependency tracking blocks incompatible drops anyway |
| Scalar UDF | `CREATE FUNCTION … IMMUTABLE/STABLE` | Mark volatility explicitly |
| Inline TVF | `RETURNS TABLE … LANGUAGE sql` | Inlines the same way |
| Multi-statement TVF | `RETURNS TABLE … LANGUAGE plpgsql` with `RETURN QUERY` | |
| Table-valued parameter | `jsonb`, or an array of a composite type | The least mechanical part of the port |
| `MERGE` | `MERGE` (PG 15+) or `INSERT … ON CONFLICT` | `OUTPUT $action` → `RETURNING` + `merge_action()` (PG 17+) |
| `OUTPUT inserted.*` | `RETURNING` | |
| `THROW 50001, 'msg', 1` | `RAISE EXCEPTION USING ERRCODE = '50001'` | Map to `SQLSTATE`s |
| `TRY/CATCH` | `BEGIN … EXCEPTION WHEN …` | |
| `SAVE TRANSACTION` | `SAVEPOINT` | |
| `XACT_ABORT` | No equivalent | PG aborts the transaction on any error by default |
| `OPENJSON … WITH` | `jsonb_to_recordset` / `jsonb_populate_recordset` | |
| `FOR JSON PATH, WITHOUT_ARRAY_WRAPPER` | `to_jsonb(row)` / `row_to_json` | |
| `ISJSON(x) = 1` | `jsonb` column type | The type enforces it |
| `PIVOT` | `FILTER (WHERE …)` aggregates, or `crosstab` | Conditional aggregation ports most cleanly |
| `CROSS APPLY` / `OUTER APPLY` | `LATERAL` / `LEFT JOIN LATERAL` | |
| Recursive CTE | `WITH RECURSIVE` | Keyword required in PG |
| `SUM() OVER (… ROWS BETWEEN …)` | Identical | Standard SQL |
| `DATEFROMPARTS` / `EOMONTH` | `make_date` / `date_trunc` + interval | |
| `SYSUTCDATETIME()` | `now() AT TIME ZONE 'utc'` | |
| `DECIMAL(19,2)` | `numeric(19,2)` | |
| `NVARCHAR(n)` | `text` or `varchar(n)` | PG is Unicode throughout |
| `SUSER_SNAME()` | `current_user` / `session_user` | |
| `sp_executesql` with params | `EXECUTE … USING` | |
| `INSTEAD OF` trigger on a view | `INSTEAD OF` trigger on a view | Direct equivalent |
| Synonym | `VIEW`, or `search_path` | No synonym object |
| `sys.objects` / `sys.sql_modules` | `pg_class` / `pg_proc` / `information_schema` | The inventory assertions need rewriting |
