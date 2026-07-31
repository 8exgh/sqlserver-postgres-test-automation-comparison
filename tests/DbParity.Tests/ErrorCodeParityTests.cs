using DbParity.Core.Targets;
using Xunit;

namespace DbParity.Tests;

/// <summary>
/// Every documented THROW code, raised on both engines and compared.
///
/// db/README.md keeps the numbers stable precisely so a harness can assert on
/// them instead of on message text, and the port carries them across as SQLSTATEs
/// (THROW 50001 became ERRCODE '50001'), so the two compare as integers.
///
/// These deliberately run WITHOUT an ambient transaction. SQL Server's procedures
/// set XACT_ABORT around their writes, and a doomed transaction can neither commit
/// nor roll back to a savepoint -- so wrapping an expected failure in a rollback
/// scope would break the scope rather than test the error. Every case here fails
/// before writing anything, which db/sqlserver/099_verify.sql relies on too.
/// </summary>
[Collection(ParityCollection.Name)]
public sealed class ErrorCodeParityTests
{
    private readonly ParityFixture _db;

    public ErrorCodeParityTests(ParityFixture db) => _db = db;

    // --- acct.usp_PostJournalEntry ---------------------------------------

    [Fact]
    public void Unbalanced_journal_entry_raises_50001() =>
        AssertPostJournalEntryRaises(50001, "unbalanced entry",
            lines: [[1, FirstPostableAccount(), 100.00m, 0.00m, "debit only"]]);

    [Fact]
    public void Unknown_account_raises_50002() =>
        AssertPostJournalEntryRaises(50002, "unknown account",
            lines:
            [
                [1, "ZZZZ", 100.00m, 0.00m, "no such account"],
                [2, FirstPostableAccount(), 0.00m, 100.00m, "credit"]
            ]);

    [Fact]
    public void Posting_to_a_control_account_raises_50003()
    {
        // Needs an open fiscal year whose client also owns a control account, so
        // the entry gets far enough to be rejected for the right reason.
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 fy.ClientId, fy.FiscalYearId, fy.StartDate,
                   (SELECT MIN(a.AccountNumber) FROM acct.Account a
                    WHERE a.ClientId = fy.ClientId AND a.IsControlAccount = 1) AS ControlAccount
            FROM acct.FiscalYear fy
            WHERE fy.IsClosed = 0
              AND EXISTS (SELECT 1 FROM acct.Account a
                          WHERE a.ClientId = fy.ClientId AND a.IsControlAccount = 1)
            ORDER BY fy.FiscalYearId
            """).Rows.FirstOrDefault();

        Assert.True(row is not null,
            "No open fiscal year has a control account. 021_seed_sample_data.sql seeds both; " +
            "re-run scripts/apply-sqlserver.sh.");

        var clientId = (int)(decimal)row![0]!;
        var control = (string)row[3]!;

        AssertRaises(50003, "control account", () => JournalArgs(
            clientId, (int)(decimal)row[1]!, (DateTime)row[2]!,
            [
                [1, control, 100.00m, 0.00m, "control debit"],
                [2, PostableAccountFor(clientId), 0.00m, 100.00m, "credit"]
            ]));
    }

    [Fact]
    public void Posting_to_a_closed_fiscal_year_raises_50004()
    {
        // The seed closes one fiscal year on purpose so this path has real data.
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 ClientId, FiscalYearId, StartDate
            FROM acct.FiscalYear WHERE IsClosed = 1 ORDER BY FiscalYearId
            """).Rows.FirstOrDefault();

        // db/README.md: one fiscal year is closed on purpose so this path has data.
        Assert.True(row is not null, "No closed fiscal year is seeded; the fixture is incomplete.");

        var clientId = (int)(decimal)row![0]!;
        var fiscalYearId = (int)(decimal)row[1]!;
        var startDate = (DateTime)row[2]!;
        var account = PostableAccountFor(clientId);

        AssertRaises(50004, "closed fiscal year", () => JournalArgs(
            clientId, fiscalYearId, startDate,
            [
                [1, account, 100.00m, 0.00m, "debit"],
                [2, account, 0.00m, 100.00m, "credit"]
            ]));
    }

    [Fact]
    public void Entry_date_outside_the_fiscal_year_raises_50005()
    {
        var (clientId, fiscalYearId, _) = OpenFiscalYear();
        var account = PostableAccountFor(clientId);

        AssertRaises(50005, "date outside fiscal year", () => JournalArgs(
            clientId, fiscalYearId, new DateTime(1999, 1, 1),
            [
                [1, account, 100.00m, 0.00m, "debit"],
                [2, account, 0.00m, 100.00m, "credit"]
            ]));
    }

    [Fact]
    public void Journal_entry_with_no_lines_raises_50006() =>
        AssertPostJournalEntryRaises(50006, "no lines", lines: []);

    // --- triggers ---------------------------------------------------------

    [Fact]
    public void Editing_a_posted_journal_line_raises_50007()
    {
        var lineId = _db.SqlServer.QueryOne("""
            SELECT TOP 1 jl.JournalLineId
            FROM acct.JournalLine jl
            JOIN acct.JournalEntry je ON je.JournalEntryId = jl.JournalEntryId
            WHERE je.IsPosted = 1
            ORDER BY jl.JournalLineId
            """).Rows.Select(r => (decimal)r[0]!).First();

        // acct.tr_JournalLine_NoPostedEdits: the books are immutable once posted.
        var sql = $"UPDATE acct.JournalLine SET Memo = 'tampered' WHERE JournalLineId = {lineId}";
        ParityAssert.SameError(_db.SqlServer.TryExecute(sql), _db.Postgres.TryExecute(sql),
            50007, "update of a posted journal line");

        var deleteSql = $"DELETE FROM acct.JournalLine WHERE JournalLineId = {lineId}";
        ParityAssert.SameError(_db.SqlServer.TryExecute(deleteSql), _db.Postgres.TryExecute(deleteSql),
            50007, "delete of a posted journal line");
    }

    [Fact]
    public void Client_directory_insert_missing_a_required_field_raises_50008()
    {
        // client.tr_ClientDirectory_Insert is an INSTEAD OF trigger that makes a
        // three-table view insertable; it rejects an incomplete row.
        // The trigger raises 50008 when ClientCode, ClientType or ProvinceCode is
        // NULL. Supplying all three lets the row through to the table's own
        // CK_Client_TypeShape check instead, which is a different error entirely.
        const string sql = """
            INSERT INTO client.vw_ClientDirectory (ClientCode, ClientType, ProvinceCode)
            VALUES ('PARITY-BAD', 'I', NULL)
            """;

        ParityAssert.SameError(_db.SqlServer.TryExecute(sql), _db.Postgres.TryExecute(sql),
            50008, "incomplete client-directory insert");
    }

    // --- tax.usp_CalculateT1 ---------------------------------------------

    [Fact]
    public void Unknown_t1_return_raises_50010() =>
        AssertRaises(50010, "unknown T1 return",
            () => ("tax", "usp_CalculateT1", new ProcArg[] { new("T1ReturnId", 999_999) }));

    [Fact]
    public void Locked_tax_year_raises_50011()
    {
        // The seed locks 2023 last, after its returns are calculated. This is the
        // case that caught the replicator not carrying ref.TaxYear.IsLocked across.
        var returnId = _db.SqlServer.QueryOne(
            "SELECT MIN(T1ReturnId) FROM tax.T1Return WHERE TaxYear = 2023").Rows[0][0];

        Assert.True(returnId is not null, "No 2023 return is seeded; the fixture is incomplete.");

        AssertRaises(50011, "locked tax year",
            () => ("tax", "usp_CalculateT1", new ProcArg[] { new("T1ReturnId", (int)(decimal)returnId!) }));
    }

    // --- tax.usp_ImportSlips ---------------------------------------------

    [Fact]
    public void Malformed_slip_json_raises_50020()
    {
        var clientId = FirstIndividualClientId();
        AssertRaises(50020, "malformed slip JSON", () => ("tax", "usp_ImportSlips", new ProcArg[]
        {
            new("ClientId", clientId),
            new("TaxYear", (short)2024),
            new("SlipsJson", "{not valid json")
        }));
    }

    [Fact]
    public void Unknown_client_raises_50021() =>
        AssertRaises(50021, "unknown client", () => ("tax", "usp_ImportSlips", new ProcArg[]
        {
            new("ClientId", 999_999),
            new("TaxYear", (short)2024),
            new("SlipsJson", "[]")
        }));

    // --- tax.usp_FileGSTHSTReturn ----------------------------------------

    [Fact]
    public void Overlapping_gsthst_period_raises_50030()
    {
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 ClientId, PeriodStart, PeriodEnd
            FROM tax.GSTHSTReturn ORDER BY GSTHSTReturnId
            """).Rows.First();

        AssertRaises(50030, "overlapping GST/HST period", () =>
            ("tax", "usp_FileGSTHSTReturn", new ProcArg[]
            {
                new("ClientId", (int)(decimal)row[0]!),
                new("PeriodStart", (DateTime)row[1]!),
                new("PeriodEnd", (DateTime)row[2]!),
                new("FrequencyCode", "Quarterly"),
                new("GSTHSTReturnId", null, IsOutput: true)
            }));
    }

    // --- client.usp_UpsertClient -----------------------------------------

    // The three checks fire in order -- shape first, then SIN, then business
    // number -- so each case has to satisfy the earlier ones to reach the one it
    // is testing. A fully-formed individual with a bad check digit, and a
    // fully-formed corporation with a bad one.

    [Fact]
    public void Invalid_sin_raises_50040() =>
        AssertRaises(50040, "invalid SIN", () => ("client", "usp_UpsertClient", UpsertArgs(
            clientType: "I", sin: "123456789")));

    [Fact]
    public void Invalid_business_number_raises_50041() =>
        AssertRaises(50041, "invalid business number", () => ("client", "usp_UpsertClient", UpsertArgs(
            clientType: "C", businessNumber: "123456780")));

    [Fact]
    public void Client_type_field_mismatch_raises_50042() =>
        // A corporation carrying an individual's fields and none of its own.
        AssertRaises(50042, "client type / field mismatch", () => ("client", "usp_UpsertClient",
        [
            new ProcArg("ClientCode", "PARITY-ERR"),
            new ProcArg("ClientType", "C"),
            new ProcArg("ProvinceCode", "ON"),
            new ProcArg("OnboardedDate", new DateTime(2024, 1, 15)),
            new ProcArg("FirstName", "Parity"),
            new ProcArg("LastName", "Probe"),
            new ProcArg("IsActive", true),
            new ProcArg("ClientId", null, IsOutput: true)
        ]));

    // --- acct.usp_GenerateInvoice ----------------------------------------

    [Fact]
    public void Invoice_with_no_lines_raises_50050()
    {
        var clientId = FirstIndividualClientId();
        var empty = new TableValue(
            "acct.InvoiceLineType", "acct.invoicelinetype",
            [("LineNumber", typeof(int)), ("Description", typeof(string)),
             ("Quantity", typeof(decimal)), ("UnitPrice", typeof(decimal)),
             ("IsTaxable", typeof(bool))],
            []);

        AssertRaises(50050, "invoice with no lines", () => ("acct", "usp_GenerateInvoice", new ProcArg[]
        {
            new("ClientId", clientId),
            new("InvoiceDate", new DateTime(2025, 3, 31)),
            new("Lines", empty),
            new("InvoiceId", null, IsOutput: true)
        }));
    }

    // --- payroll.usp_RunPayroll ------------------------------------------

    [Fact]
    public void Reprocessing_a_pay_period_without_force_raises_50060()
    {
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 pp.ClientId, pp.PayPeriodId
            FROM payroll.PayPeriod pp
            WHERE EXISTS (SELECT 1 FROM payroll.PayStub ps WHERE ps.PayPeriodId = pp.PayPeriodId)
            ORDER BY pp.PayPeriodId
            """).Rows.First();

        AssertRaises(50060, "pay period already processed", () => ("payroll", "usp_RunPayroll", new ProcArg[]
        {
            new("ClientId", (int)(decimal)row[0]!),
            new("PayPeriodId", (int)(decimal)row[1]!),
            new("Force", false)
        }));
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------

    private void AssertRaises(int expected, string context,
                              Func<(string Schema, string Name, ProcArg[] Args)> build)
    {
        var (schema, name, args) = build();
        ParityAssert.SameError(
            _db.SqlServer.TryCallProcedure(schema, name, args),
            _db.Postgres.TryCallProcedure(schema, name, args),
            expected, context);
    }

    private void AssertPostJournalEntryRaises(int expected, string context, object?[][] lines)
    {
        var (clientId, fiscalYearId, entryDate) = OpenFiscalYear();
        AssertRaises(expected, context, () => JournalArgs(clientId, fiscalYearId, entryDate, lines));
    }

    private static (string, string, ProcArg[]) JournalArgs(
        int clientId, int fiscalYearId, DateTime entryDate, object?[][] lines) =>
        ("acct", "usp_PostJournalEntry",
        [
            new ProcArg("ClientId", clientId),
            new ProcArg("FiscalYearId", fiscalYearId),
            new ProcArg("EntryDate", entryDate),
            new ProcArg("Description", "parity error probe"),
            new ProcArg("Lines", new TableValue(
                "acct.JournalLineType", "acct.journallinetype",
                [("LineNumber", typeof(int)), ("AccountNumber", typeof(string)),
                 ("DebitAmount", typeof(decimal)), ("CreditAmount", typeof(decimal)),
                 ("Memo", typeof(string))],
                lines)),
            new ProcArg("Source", "Manual"),
            new ProcArg("PostedBy", "parity"),
            new ProcArg("PostImmediately", true),
            new ProcArg("JournalEntryId", null, IsOutput: true)
        ]);

    /// <summary>
    /// A well-formed client of the given type, so the only thing wrong with it is
    /// whatever the caller deliberately breaks.
    /// </summary>
    private static ProcArg[] UpsertArgs(
        string clientType,
        string? sin = null,
        string? businessNumber = null)
    {
        var individual = clientType == "I";
        return
        [
            new ProcArg("ClientCode", "PARITY-ERR"),
            new ProcArg("ClientType", clientType),
            new ProcArg("ProvinceCode", "ON"),
            new ProcArg("OnboardedDate", new DateTime(2024, 1, 15)),
            new ProcArg("FirstName", individual ? "Parity" : null),
            new ProcArg("LastName", individual ? "Probe" : null),
            new ProcArg("DateOfBirth", individual ? new DateTime(1980, 5, 5) : null),
            new ProcArg("SIN", sin),
            new ProcArg("LegalName", individual ? null : "Parity Holdings Inc."),
            new ProcArg("IncorporationDate", individual ? null : new DateTime(2010, 3, 1)),
            new ProcArg("FiscalYearEndMonth", individual ? null : 12),
            new ProcArg("BusinessNumber", businessNumber),
            new ProcArg("IsActive", true),
            new ProcArg("ClientId", null, IsOutput: true)
        ];
    }

    private (int ClientId, int FiscalYearId, DateTime EntryDate) OpenFiscalYear()
    {
        var row = _db.SqlServer.QueryOne("""
            SELECT TOP 1 ClientId, FiscalYearId, StartDate
            FROM acct.FiscalYear WHERE IsClosed = 0 ORDER BY FiscalYearId
            """).Rows[0];

        return ((int)(decimal)row[0]!, (int)(decimal)row[1]!, (DateTime)row[2]!);
    }

    private string FirstPostableAccount() => PostableAccountFor(OpenFiscalYear().ClientId);

    private string PostableAccountFor(int clientId) =>
        (string)_db.SqlServer.QueryOne($"""
            SELECT TOP 1 AccountNumber FROM acct.Account
            WHERE ClientId = {clientId} AND IsControlAccount = 0 AND IsActive = 1
            ORDER BY AccountNumber
            """).Rows[0][0]!;

    private int FirstIndividualClientId() =>
        (int)(decimal)_db.SqlServer.QueryOne(
            "SELECT MIN(ClientId) FROM client.Client WHERE ClientType = 'I'").Rows[0][0]!;
}
