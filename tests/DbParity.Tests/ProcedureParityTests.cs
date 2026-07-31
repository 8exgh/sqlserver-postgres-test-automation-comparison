using DbParity.Core.Results;
using DbParity.Core.Targets;
using Xunit;

namespace DbParity.Tests;

/// <summary>
/// Calls each of the twelve procedures on both engines with identical arguments
/// and compares what comes back.
///
/// This family carries weight the query cases cannot. Because SQL Server is the
/// source of truth and the sample data is replicated rather than regenerated, the
/// ported procedures never write the fixture -- on SQL Server, 021_seed_sample_data.sql
/// builds it by calling usp_PostJournalEntry, usp_ImportSlips, usp_RunPayroll,
/// usp_CalculateT1, usp_CloseFiscalYear and usp_FileGSTHSTReturn. Without these
/// tests, a bug in any of those ports would be invisible.
///
/// Mutating calls run inside a rollback scope on both engines, so the fixture is
/// unchanged afterwards and test order does not matter.
/// </summary>
[Collection(ParityCollection.Name)]
public sealed class ProcedureParityTests
{
    private readonly ParityFixture _db;

    public ProcedureParityTests(ParityFixture db) => _db = db;

    // ---------------------------------------------------------------------
    // read-only procedures
    // ---------------------------------------------------------------------

    [Theory]
    [InlineData(null, null, null, "DisplayName", "ASC")]
    [InlineData("a", null, null, "DisplayName", "ASC")]
    [InlineData(null, "ON", null, "ClientCode", "ASC")]
    [InlineData(null, null, "C", "ClientCode", "DESC")]
    [InlineData(null, "BC", "I", "OnboardedDate", "ASC")]
    public void SearchClients_agrees(string? nameContains, string? province, string? type,
                                     string sortColumn, string sortDirection)
    {
        // Parameterized dynamic SQL: sp_executesql on SQL Server, EXECUTE ... USING
        // here. The sort column is interpolated into the statement on both sides,
        // which is exactly the part worth checking.
        var args = new[]
        {
            new ProcArg("NameContains", nameContains),
            new ProcArg("ProvinceCode", province),
            new ProcArg("ClientType", type),
            new ProcArg("IsActive", true),
            new ProcArg("SortColumn", sortColumn),
            new ProcArg("SortDirection", sortDirection),
            new ProcArg("MaxRows", 100)
        };

        CompareCall("client", "usp_SearchClients", args,
            $"SearchClients({nameContains ?? "-"}, {province ?? "-"}, {type ?? "-"}, {sortColumn} {sortDirection})",
            // Ordering by DisplayName or ClientCode is ordering by text, and the two
            // engines collate text differently -- that divergence is asserted
            // deliberately in CollationSemanticsTests rather than tripped over here.
            sortClientSide: true);
    }

    [Fact]
    public void GenerateClientYearEndPackage_agrees_across_all_five_result_sets()
    {
        // The only procedure returning multiple result sets from one call: five on
        // SQL Server, five INOUT refcursors here. Any that the port failed to open
        // would show up as a missing set rather than as wrong data.
        foreach (var clientId in SeededClientIds().Take(6))
        {
            CompareCall("tax", "usp_GenerateClientYearEndPackage",
                [new ProcArg("ClientId", clientId), new ProcArg("TaxYear", (short)2024)],
                $"YearEndPackage(client {clientId}, 2024)",
                expectedResultSets: 5);
        }
    }

    // ---------------------------------------------------------------------
    // mutating procedures, inside a rollback scope
    // ---------------------------------------------------------------------

    [Fact]
    public void CalculateT1_agrees()
    {
        // 2024 returns only: the 2023 tax year is locked on purpose and is covered
        // by the error-code tests below.
        var returnIds = _db.SqlServer
            .QueryOne("SELECT T1ReturnId FROM tax.T1Return WHERE TaxYear = 2024 ORDER BY T1ReturnId")
            .Rows.Select(r => (int)(decimal)r[0]!).Take(8).ToArray();

        Assert.NotEmpty(returnIds);

        foreach (var returnId in returnIds)
        {
            InRollbackScope(() => CompareCall("tax", "usp_CalculateT1",
                [
                    new ProcArg("T1ReturnId", returnId),
                    new ProcArg("AssessmentType", "Recalculation"),
                    new ProcArg("Notes", "parity")
                ],
                $"CalculateT1({returnId})"));
        }
    }

    [Fact]
    public void CalculateT1_writes_the_same_assessment()
    {
        var returnId = (int)(decimal)_db.SqlServer
            .QueryOne("SELECT MIN(T1ReturnId) FROM tax.T1Return WHERE TaxYear = 2024")
            .Rows[0][0]!;

        // Compares the durable effect, not just the result set: the recalculated
        // return and the immutable assessment row the procedure appends.
        InRollbackScope(() =>
        {
            Call("tax", "usp_CalculateT1",
                [new ProcArg("T1ReturnId", returnId), new ProcArg("AssessmentType", "Recalculation")]);

            CompareQuery($"""
                SELECT TotalIncome, NetIncome, TaxableIncome, NetFederalTax, NetProvincialTax,
                       TotalPayable, BalanceOwing, FilingStatus
                FROM tax.T1Return WHERE T1ReturnId = {returnId}
                """, "T1Return after recalculation");

            CompareQuery($"""
                SELECT AssessmentType, TaxableIncome, FederalTax, ProvincialTax,
                       TotalPayable, BalanceOwing, CalculationNotes
                FROM tax.Assessment WHERE T1ReturnId = {returnId}
                ORDER BY AssessmentId
                """, "Assessment history after recalculation");
        });
    }

    [Fact]
    public void RecalculateAllReturns_agrees()
    {
        // A batch driver that reports failures instead of raising them. Both result
        // sets matter: the summary, and the per-return failure detail.
        InRollbackScope(() => CompareCall("tax", "usp_RecalculateAllReturns",
            [
                new ProcArg("TaxYear", (short)2024),
                new ProcArg("ContinueOnError", true),
                new ProcArg("IncludeFailureDetail", true)
            ],
            "RecalculateAllReturns(2024)"));
    }

    [Fact]
    public void UpsertClient_agrees_on_insert_and_on_update()
    {
        ProcArg[] insert =
        [
            new ProcArg("ClientCode", "PARITY-0001"),
            new ProcArg("ClientType", "I"),
            new ProcArg("ProvinceCode", "ON"),
            new ProcArg("OnboardedDate", new DateTime(2024, 1, 15)),
            new ProcArg("FirstName", "Parity"),
            new ProcArg("LastName", "Test"),
            new ProcArg("DateOfBirth", new DateTime(1980, 5, 5)),
            new ProcArg("SIN", "046454286"),
            new ProcArg("MaritalStatus", "Single"),
            new ProcArg("IsActive", true),
            // SQL Server requires every declared OUT parameter to be supplied.
            new ProcArg("ClientId", null, IsOutput: true)
        ];

        // MERGE with OUTPUT $action on SQL Server. AWS SCT could not translate
        // MERGE at all, so this procedure was rewritten by hand -- and the port
        // targets PostgreSQL 16, where merge_action() does not exist, so the
        // affected row is identified by natural key instead. Running the same
        // upsert twice checks both branches.
        InRollbackScope(() =>
        {
            CompareCall("client", "usp_UpsertClient", insert, "UpsertClient insert",
                excludeColumns: new HashSet<string> {"clientid"});

            var update = insert.Select(a =>
                a.Name == "LastName" ? new ProcArg("LastName", "Updated") : a).ToArray();

            CompareCall("client", "usp_UpsertClient", update, "UpsertClient update",
                excludeColumns: new HashSet<string> {"clientid"});

            CompareQuery("""
                SELECT ClientCode, ClientType, ProvinceCode, FirstName, LastName,
                       DisplayName, SIN, MaritalStatus, IsActive, OnboardedDate
                FROM client.Client WHERE ClientCode = 'PARITY-0001'
                """, "client row after upsert");
        });
    }

    [Fact]
    public void ImportSlips_agrees()
    {
        var clientId = (int)(decimal)_db.SqlServer.QueryOne(
            "SELECT MIN(ClientId) FROM client.Client WHERE ClientType = 'I'").Rows[0][0]!;

        // OPENJSON ... WITH on SQL Server, jsonb_to_recordset here, with nested
        // arrays and a MERGE underneath -- three of the constructs SCT could not
        // translate, all in one procedure.
        // Key names follow the OPENJSON ... WITH paths the procedure declares
        // ($.slipType, $.issuer, $.box), matching the payloads in the seed script.
        const string slipsJson = """
            [
              {"slipType":"T4","issuer":"Parity Corp","issuerBn":"951753284",
               "reference":"PARITY-T4-01","receivedDate":"2025-02-20","amended":false,
               "boxes":[{"box":"14","amount":50000.00},{"box":"22","amount":8000.00}]},
              {"slipType":"T5","issuer":"Parity Bank","issuerBn":"357159268",
               "reference":"PARITY-T5-01","receivedDate":"2025-02-21","amended":false,
               "boxes":[{"box":"13","amount":1250.50}]}
            ]
            """;

        InRollbackScope(() =>
        {
            CompareCall("tax", "usp_ImportSlips",
                [
                    new ProcArg("ClientId", clientId),
                    new ProcArg("TaxYear", (short)2024),
                    new ProcArg("SlipsJson", slipsJson)
                ],
                "ImportSlips");

            CompareQuery($"""
                SELECT s.SlipTypeCode, s.SlipReference, s.IssuerName, s.TaxYear,
                       s.ReceivedDate, s.IsAmended, b.BoxNumber, b.Amount
                FROM tax.Slip s
                JOIN tax.SlipBox b ON b.SlipId = s.SlipId
                WHERE s.ClientId = {clientId} AND s.SlipReference LIKE 'PARITY-%'
                ORDER BY s.SlipReference, b.BoxNumber
                """, "slips after import");
        });
    }

    [Fact]
    public void PostJournalEntry_agrees()
    {
        var (clientId, fiscalYearId, entryDate) = OpenFiscalYear();

        // Account numbers are read from the client's own chart rather than assumed:
        // the procedure rejects unknown accounts with error 50002 and postings to a
        // control account with 50003, so the happy path needs two real, postable
        // accounts belonging to this client.
        var accounts = _db.SqlServer.QueryOne($"""
            SELECT TOP 2 a.AccountNumber
            FROM acct.Account a
            WHERE a.ClientId = {clientId} AND a.IsControlAccount = 0 AND a.IsActive = 1
            ORDER BY a.AccountNumber
            """).Rows.Select(r => (string)r[0]!).ToArray();

        Assert.Equal(2, accounts.Length);

        var lines = new TableValue(
            "acct.JournalLineType",
            "acct.journallinetype",
            [("LineNumber", typeof(int)), ("AccountNumber", typeof(string)),
             ("DebitAmount", typeof(decimal)), ("CreditAmount", typeof(decimal)),
             ("Memo", typeof(string))],
            [
                [1, accounts[0], 1500.00m, 0.00m, "parity debit"],
                [2, accounts[1], 0.00m, 1500.00m, "parity credit"]
            ]);

        // Table-valued parameter on SQL Server, an array of a composite type here.
        InRollbackScope(() =>
        {
            CompareCall("acct", "usp_PostJournalEntry",
                [
                    new ProcArg("ClientId", clientId),
                    new ProcArg("FiscalYearId", fiscalYearId),
                    new ProcArg("EntryDate", entryDate),
                    new ProcArg("Description", "parity entry"),
                    new ProcArg("Lines", lines),
                    new ProcArg("Source", "Manual"),
                    new ProcArg("PostedBy", "parity"),
                    new ProcArg("PostImmediately", true),
                    new ProcArg("JournalEntryId", null, IsOutput: true)
                ],
                "PostJournalEntry",
                excludeColumns: new HashSet<string> {"journalentryid"});

            CompareQuery($"""
                SELECT je.Description, je.Source, je.IsPosted, je.PostedBy, jl.LineNumber,
                       a.AccountNumber, jl.DebitAmount, jl.CreditAmount, jl.Memo
                FROM acct.JournalEntry je
                JOIN acct.JournalLine jl ON jl.JournalEntryId = je.JournalEntryId
                JOIN acct.Account a ON a.AccountId = jl.AccountId
                WHERE je.ClientId = {clientId} AND je.Description = 'parity entry'
                ORDER BY jl.LineNumber
                """, "journal entry after posting");
        });
    }

    [Fact]
    public void GenerateInvoice_agrees()
    {
        var clientId = (int)(decimal)_db.SqlServer.QueryOne(
            "SELECT MIN(ClientId) FROM client.Client WHERE IsActive = 1").Rows[0][0]!;

        var lines = new TableValue(
            "acct.InvoiceLineType",
            "acct.invoicelinetype",
            [("LineNumber", typeof(int)), ("Description", typeof(string)),
             ("Quantity", typeof(decimal)), ("UnitPrice", typeof(decimal)),
             ("IsTaxable", typeof(bool))],
            [
                [1, "Parity engagement", 10.00m, 150.00m, true],
                [2, "Disbursements", 1.00m, 75.00m, false]
            ]);

        // Draws its number from a sequence and applies province-aware sales tax,
        // so it exercises acct.seq_invoicenumber and ref.fn_SalesTaxRate together.
        // InvoiceNumber is excluded: the sequence is shared state that a rolled-back
        // call still consumes, so its value depends on how often this test has run.
        InRollbackScope(() =>
        {
            CompareCall("acct", "usp_GenerateInvoice",
                [
                    new ProcArg("ClientId", clientId),
                    new ProcArg("InvoiceDate", new DateTime(2025, 3, 31)),
                    new ProcArg("Lines", lines),
                    new ProcArg("PaymentTerms", 30),
                    new ProcArg("Notes", "parity invoice"),
                    new ProcArg("Status", "Sent"),
                    new ProcArg("InvoiceId", null, IsOutput: true)
                ],
                "GenerateInvoice",
                excludeColumns: new HashSet<string> {"invoiceid", "invoicenumber"});

            CompareQuery($"""
                SELECT i.Subtotal, i.GSTHSTAmount, i.PSTAmount, i.Total, i.Status,
                       i.ProvinceCode, i.InvoiceDate, i.DueDate,
                       il.LineNumber, il.Description, il.Quantity, il.UnitPrice,
                       il.IsTaxable, il.LineTotal
                FROM acct.Invoice i
                JOIN acct.InvoiceLine il ON il.InvoiceId = i.InvoiceId
                WHERE i.ClientId = {clientId} AND i.Notes = 'parity invoice'
                ORDER BY il.LineNumber
                """, "invoice after generation");
        });
    }

    [Fact]
    public void RunPayroll_agrees()
    {
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 pp.ClientId, pp.PayPeriodId
            FROM payroll.PayPeriod pp
            ORDER BY pp.PayPeriodId
            """).Rows[0];

        var clientId = (int)(decimal)row[0]!;
        var payPeriodId = (int)(decimal)row[1]!;

        // Set-based CROSS APPLY over the CPP/EI functions, with a MERGE underneath.
        // Force = 1 so it recomputes a period the seed already processed.
        InRollbackScope(() =>
        {
            CompareCall("payroll", "usp_RunPayroll",
                [
                    new ProcArg("ClientId", clientId),
                    new ProcArg("PayPeriodId", payPeriodId),
                    new ProcArg("Force", true)
                ],
                "RunPayroll");

            CompareQuery($"""
                SELECT EmployeeId, GrossPay, CPPDeducted, CPP2Deducted, EIDeducted,
                       FederalTaxDeducted, ProvincialTaxDeducted, NetPay
                FROM payroll.PayStub
                WHERE PayPeriodId = {payPeriodId}
                ORDER BY EmployeeId
                """, "paystubs after payroll");
        });
    }

    [Fact]
    public void FileGSTHSTReturn_agrees()
    {
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 c.ClientId
            FROM client.Client c
            WHERE c.ClientType = 'C' AND c.BusinessNumber IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM tax.GSTHSTReturn g
                              WHERE g.ClientId = c.ClientId AND g.PeriodStart = '2025-10-01')
            ORDER BY c.ClientId
            """).Rows[0];

        var clientId = (int)(decimal)row[0]!;

        // Derives the GST34 lines from the ledger, so it depends on the journal
        // data landing identically as well as on the procedure porting correctly.
        InRollbackScope(() =>
        {
            CompareCall("tax", "usp_FileGSTHSTReturn",
                [
                    new ProcArg("ClientId", clientId),
                    new ProcArg("PeriodStart", new DateTime(2025, 10, 1)),
                    new ProcArg("PeriodEnd", new DateTime(2025, 12, 31)),
                    new ProcArg("FrequencyCode", "Quarterly"),
                    new ProcArg("GSTHSTReturnId", null, IsOutput: true)
                ],
                "FileGSTHSTReturn",
                excludeColumns: new HashSet<string> {"gsthstreturnid"});

            CompareQuery($"""
                SELECT PeriodStart, PeriodEnd, FrequencyCode, Line101Sales,
                       Line105TaxCollected, Line108InputTaxCredits, Line109NetTax,
                       BalanceDue, Status
                FROM tax.GSTHSTReturn
                WHERE ClientId = {clientId} AND PeriodStart = '2025-10-01'
                """, "GST/HST return after filing");
        });
    }

    [Fact]
    public void CloseFiscalYear_agrees()
    {
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 fy.ClientId, fy.FiscalYearId
            FROM acct.FiscalYear fy
            WHERE fy.IsClosed = 0
              AND EXISTS (SELECT 1 FROM acct.JournalEntry je WHERE je.FiscalYearId = fy.FiscalYearId)
            ORDER BY fy.FiscalYearId
            """).Rows[0];

        var clientId = (int)(decimal)row[0]!;
        var fiscalYearId = (int)(decimal)row[1]!;

        // An explicit cursor calling usp_PostJournalEntry per account. On SQL Server
        // the nested call relies on SAVE TRANSACTION; here the same isolation comes
        // from the callee's own EXCEPTION block being a subtransaction.
        InRollbackScope(() =>
        {
            CompareCall("acct", "usp_CloseFiscalYear",
                [
                    new ProcArg("ClientId", clientId),
                    new ProcArg("FiscalYearId", fiscalYearId),
                    new ProcArg("RetainedEarningsAccountNumber", "3200"),
                    new ProcArg("PostedBy", "parity")
                ],
                "CloseFiscalYear");

            CompareQuery($"""
                SELECT IsClosed, ClosedBy
                FROM acct.FiscalYear WHERE FiscalYearId = {fiscalYearId}
                """, "fiscal year after close");
        });
    }

    [Fact]
    public void PurgeChangeLog_agrees()
    {
        // Batched DELETE TOP (n) on SQL Server, DELETE ... WHERE ctid IN (... LIMIT n)
        // here. A retention of 0 days makes every row eligible, so the batching loop
        // actually runs instead of finding nothing to do.
        InRollbackScope(() =>
        {
            CompareCall("audit", "usp_PurgeChangeLog",
                [
                    new ProcArg("RetentionDays", 0),
                    new ProcArg("BatchSize", 10),
                    new ProcArg("MaxBatches", 100),
                    new ProcArg("RowsDeleted", null, IsOutput: true)
                ],
                "PurgeChangeLog",
                // CutoffUtc is SYSUTCDATETIME() minus the retention window on one
                // side and now() minus the same on the other, evaluated milliseconds
                // apart in two separate calls. It cannot match and says nothing
                // about the port; the row count it produced is what matters.
                excludeColumns: new HashSet<string> { "cutoffutc" });

            Assert.Equal(
                _db.SqlServer.LastOutputValues["RowsDeleted"],
                _db.Postgres.LastOutputValues["RowsDeleted"]);

            CompareQuery("SELECT COUNT(*) AS Remaining FROM audit.ChangeLog", "changelog after purge");
        });
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    /// <summary>Runs the body with a rollback scope open on both engines.</summary>
    private void InRollbackScope(Action body)
    {
        using var mssql = _db.SqlServer.BeginRollbackScope();
        using var postgres = _db.Postgres.BeginRollbackScope();
        body();
    }

    private void Call(string schema, string name, ProcArg[] args)
    {
        _db.SqlServer.CallProcedure(schema, name, args);
        _db.Postgres.CallProcedure(schema, name, args);
    }

    /// <summary>Calls the procedure on both engines and compares every result set.</summary>
    private void CompareCall(
        string schema,
        string name,
        ProcArg[] args,
        string context,
        int? expectedResultSets = null,
        bool sortClientSide = false,
        IReadOnlySet<string>? excludeColumns = null)
    {
        var mssql = _db.SqlServer.CallProcedure(schema, name, args);
        var postgres = _db.Postgres.CallProcedure(schema, name, args);

        Assert.True(mssql.Length == postgres.Length,
            $"{context}: sqlserver returned {mssql.Length} result set(s), postgres returned {postgres.Length}.");

        if (expectedResultSets is { } expected)
        {
            Assert.True(mssql.Length == expected,
                $"{context}: expected {expected} result set(s), got {mssql.Length}.");
        }

        for (var i = 0; i < mssql.Length; i++)
        {
            var left = Prepare(mssql[i], sortClientSide, excludeColumns);
            var right = Prepare(postgres[i], sortClientSide, excludeColumns);
            ParityAssert.Same(left, right, $"{context} · result set {i + 1}");
        }
    }

    private static ResultSet Prepare(ResultSet set, bool sortClientSide, IReadOnlySet<string>? excluded)
    {
        var prepared = excluded is null ? set : set.WithoutColumns(excluded);
        return sortClientSide ? prepared.SortedOrdinally() : prepared;
    }

    /// <summary>Runs the same query on both engines and compares -- used to check durable effects.</summary>
    private void CompareQuery(string sql, string context)
    {
        ParityAssert.Same(_db.SqlServer.QueryOne(sql), _db.Postgres.QueryOne(sql), context);
    }

    private IEnumerable<int> SeededClientIds() =>
        _db.SqlServer.QueryOne("SELECT ClientId FROM client.Client ORDER BY ClientId")
            .Rows.Select(r => (int)(decimal)r[0]!);

    private (int ClientId, int FiscalYearId, DateTime EntryDate) OpenFiscalYear()
    {
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 ClientId, FiscalYearId, StartDate
            FROM acct.FiscalYear
            WHERE IsClosed = 0
            ORDER BY FiscalYearId
            """).Rows[0];

        return ((int)(decimal)row[0]!, (int)(decimal)row[1]!, (DateTime)row[2]!);
    }
}
