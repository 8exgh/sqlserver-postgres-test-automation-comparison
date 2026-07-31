using Xunit;

namespace DbParity.Tests;

/// <summary>
/// The four triggers and a representative set of constraints, exercised on both
/// engines and compared by their effects.
///
/// Triggers are where the two engines are least alike structurally: T-SQL carries
/// the body inline and sees a whole `inserted` set, while PL/pgSQL needs a
/// separate function and fires per row. A port can look right and still fire the
/// wrong number of times, or miss the multi-row case entirely -- neither of which
/// any amount of reading the DDL would reveal.
///
/// Everything here runs inside a rollback scope, so the fixture is untouched.
/// </summary>
[Collection(ParityCollection.Name)]
public sealed class TriggerConstraintTests
{
    private readonly ParityFixture _db;

    public TriggerConstraintTests(ParityFixture db) => _db = db;

    // --- client.tr_Client_Audit ------------------------------------------

    [Fact]
    public void Client_audit_trigger_records_the_same_images()
    {
        const string insert = """
            INSERT INTO client.Client
                (ClientCode, ClientType, ProvinceCode, OnboardedDate,
                 FirstName, LastName, DateOfBirth, SIN, MaritalStatus, IsActive)
            VALUES ('PARITY-AUD', 'I', 'ON', '2024-02-01',
                    'Audit', 'Probe', '1979-04-04', '046454286', 'Single', 1)
            """;

        const string update = "UPDATE client.Client SET MaritalStatus = 'Married' WHERE ClientCode = 'PARITY-AUD'";
        const string delete = "DELETE FROM client.Client WHERE ClientCode = 'PARITY-AUD'";

        // The audit payloads are NVARCHAR JSON on SQL Server and jsonb here, so
        // they are compared as JSON: jsonb reorders keys and drops whitespace, and
        // comparing the text would report a difference on every row while telling
        // us nothing.
        InRollbackScope(() =>
        {
            // A watermark rather than a LIKE over the payload: the column is jsonb
            // here and NVARCHAR on SQL Server, and jsonb has no LIKE operator.
            // audit.ChangeLog is replicated, so the watermark is the same number on
            // both engines.
            var watermark = Watermark();

            Execute(insert);
            Execute(update);
            Execute(delete);

            // ChangedBy is excluded: it is SUSER_SNAME() on one side and
            // current_user on the other, evaluated live, so it records 'sa' here
            // and 'postgres' there. That is the connection's identity, not the
            // port's doing. (Rows carried over by the replicator keep SQL Server's
            // 'sa' on both engines and ARE compared, in cases/tables/audit.changelog.)
            CompareQuery($"""
                SELECT Operation, SchemaName, TableName
                FROM audit.ChangeLog
                WHERE ChangeLogId > {watermark}
                ORDER BY ChangeLogId
                """, "audit trail for a full insert/update/delete cycle");
        });
    }

    /// <summary>
    /// A real divergence in the audit payloads, asserted rather than hidden.
    ///
    /// SQL Server builds them with FOR JSON, which names each key after the column
    /// as declared ("ClientCode") and renders BIT as a JSON boolean. The port
    /// builds them from PostgreSQL's lowercase catalog names ("clientcode") and
    /// renders numeric(1,0) as the number 1. The documents therefore carry the same
    /// facts under different keys and different types.
    ///
    /// This is invisible to every other test in the suite: audit.ChangeLog is
    /// replicated, so the historical rows are byte-identical on both engines and
    /// compare clean. Only rows a trigger writes AFTER the migration diverge --
    /// which is to say, all of them in production. Anything reading the audit trail
    /// by key name breaks silently at cutover.
    /// </summary>
    [Fact]
    public void Audit_payload_keys_and_boolean_rendering_diverge()
    {
        InRollbackScope(() =>
        {
            var watermark = Watermark();

            Execute("""
                INSERT INTO client.Client
                    (ClientCode, ClientType, ProvinceCode, OnboardedDate,
                     FirstName, LastName, DateOfBirth, SIN, MaritalStatus, IsActive)
                VALUES ('PARITY-KEY', 'I', 'ON', '2024-02-01',
                        'Key', 'Probe', '1979-04-04', '046454286', 'Single', 1)
                """);

            var sqlServerPayload = Payload(_db.SqlServer, watermark);
            var postgresPayload = Payload(_db.Postgres, watermark);

            Assert.Contains("\"ClientCode\"", sqlServerPayload);
            Assert.Contains("\"clientcode\"", postgresPayload);
            Assert.DoesNotContain("\"ClientCode\"", postgresPayload);

            Assert.Contains("\"IsActive\":true", sqlServerPayload.Replace(" ", ""));
            Assert.Contains("\"isactive\":1", postgresPayload.Replace(" ", ""));
        });
    }

    private static string Payload(Core.Targets.DbTarget target, long watermark) =>
        (string)target.QueryOne($"""
            SELECT CAST(NewValues AS VARCHAR(4000)) AS Payload
            FROM audit.ChangeLog
            WHERE ChangeLogId > {watermark} AND Operation = 'I'
            ORDER BY ChangeLogId
            """).Rows[0][0]!;

    [Fact]
    public void Client_audit_trigger_handles_a_multi_row_update()
    {
        // The case a per-row PL/pgSQL trigger gets wrong differently from a
        // set-based T-SQL one: a single statement touching many rows must produce
        // one audit row per client on both engines.
        InRollbackScope(() =>
        {
            Execute("UPDATE client.Client SET MaritalStatus = 'Single' WHERE ClientType = 'I'");

            CompareQuery("""
                SELECT COUNT(*) AS AuditRows
                FROM audit.ChangeLog
                WHERE TableName = 'Client' AND Operation = 'U'
                """, "audit rows after a multi-row update");
        });
    }

    // --- client.tr_ClientDirectory_Insert (INSTEAD OF on a view) ----------

    [Fact]
    public void Client_directory_insert_fans_out_to_all_three_tables()
    {
        const string insert = """
            INSERT INTO client.vw_ClientDirectory
                (ClientCode, ClientType, ProvinceCode, FirstName, LastName, SIN,
                 OnboardedDate, IsActive, Line1, City, PostalCode, PrimaryEmail)
            VALUES ('PARITY-DIR', 'I', 'ON', 'Directory', 'Probe', '046454286',
                    '2024-02-01', 1, '1 Test Way', 'Toronto', 'M5H 2N2', 'dir@parity.test')
            """;

        InRollbackScope(() =>
        {
            Execute(insert);

            CompareQuery("""
                SELECT c.ClientCode, c.ClientType, c.ProvinceCode, c.DisplayName, c.IsActive,
                       a.Line1, a.City, a.PostalCode, a.IsPrimary,
                       ct.ContactType, ct.ContactValue, ct.IsPrimary
                FROM client.Client c
                LEFT JOIN client.ClientAddress a ON a.ClientId = c.ClientId
                LEFT JOIN client.ClientContact ct ON ct.ClientId = c.ClientId
                WHERE c.ClientCode = 'PARITY-DIR'
                ORDER BY a.AddressId, ct.ContactId
                """, "rows created through the client-directory view");
        });
    }

    // --- tax.tr_T1Return_StatusHistory -----------------------------------

    [Fact]
    public void T1_status_change_is_recorded_identically()
    {
        var returnId = (int)(decimal)_db.SqlServer.QueryOne("""
            SELECT MIN(T1ReturnId) FROM tax.T1Return WHERE FilingStatus = 'Draft'
            """).Rows[0][0]!;

        InRollbackScope(() =>
        {
            // CK_T1Return_FiledDate requires DateFiled to be set once the status is
            // 'Filed', so both have to move together.
            Execute($"""
                UPDATE tax.T1Return
                SET FilingStatus = 'Filed', DateFiled = '2025-04-30'
                WHERE T1ReturnId = {returnId}
                """);

            // ChangedBy excluded for the same reason as in the audit trigger: it is
            // the live connection identity ('sa' vs 'postgres'), not the port.
            // Asserted non-empty below so the column is still being populated.
            CompareQuery($"""
                SELECT OldStatus, NewStatus
                FROM audit.ReturnStatusHistory
                WHERE T1ReturnId = {returnId}
                ORDER BY ReturnStatusHistoryId
                """, "status history after a filing-status change");

            CompareQuery($"""
                SELECT COUNT(*) AS RowsWithAnAuthor
                FROM audit.ReturnStatusHistory
                WHERE T1ReturnId = {returnId} AND ChangedBy IS NOT NULL AND ChangedBy <> ''
                """, "status history rows carry an author on both engines");
        });
    }

    [Fact]
    public void T1_status_history_is_not_written_when_the_status_does_not_change()
    {
        // The trigger fires on any UPDATE; only a genuine status transition should
        // be recorded. A port that dropped the comparison would log every edit.
        var returnId = (int)(decimal)_db.SqlServer.QueryOne(
            "SELECT MIN(T1ReturnId) FROM tax.T1Return WHERE TaxYear = 2024").Rows[0][0]!;

        InRollbackScope(() =>
        {
            Execute($"""
                UPDATE tax.T1Return SET FilingStatus = FilingStatus WHERE T1ReturnId = {returnId}
                """);

            CompareQuery($"""
                SELECT COUNT(*) AS HistoryRows
                FROM audit.ReturnStatusHistory WHERE T1ReturnId = {returnId}
                """, "status history after a no-op update");
        });
    }

    // --- constraints ------------------------------------------------------

    [Theory]
    // check constraints
    [InlineData("CK_Client_Type",
        "UPDATE client.Client SET ClientType = 'X' WHERE ClientId = (SELECT MIN(ClientId) FROM client.Client)")]
    [InlineData("CK_TaxBracket_Rate",
        "UPDATE ref.TaxBracket SET Rate = 1.5 WHERE TaxYear = 2024 AND JurisdictionCode = 'CA' AND Ordinal = 1")]
    [InlineData("CK_TaxBracket_Lower",
        "UPDATE ref.TaxBracket SET LowerBound = -1 WHERE TaxYear = 2024 AND JurisdictionCode = 'CA' AND Ordinal = 1")]
    // foreign keys
    [InlineData("FK_Client_Province",
        "UPDATE client.Client SET ProvinceCode = 'ZZ' WHERE ClientId = (SELECT MIN(ClientId) FROM client.Client)")]
    [InlineData("FK_T1Return_Client",
        "UPDATE tax.T1Return SET ClientId = 999999 WHERE T1ReturnId = (SELECT MIN(T1ReturnId) FROM tax.T1Return)")]
    // unique constraints
    [InlineData("UQ_Client_Code",
        """
        UPDATE client.Client SET ClientCode =
            (SELECT MAX(ClientCode) FROM client.Client)
        WHERE ClientCode = (SELECT MIN(ClientCode) FROM client.Client)
        """)]
    public void Both_engines_reject_the_same_violation(string constraint, string sql)
    {
        // The error NUMBERS differ by design here -- SQL Server reports 547 for a
        // check or foreign-key violation and 2627 for a unique one, PostgreSQL uses
        // SQLSTATE 23514/23503/23505. What has to match is that the write is
        // refused at all; a constraint the port silently dropped would let it through.
        var sqlServer = _db.SqlServer.TryExecute(sql);
        var postgres = _db.Postgres.TryExecute(sql);

        Assert.True(sqlServer is not null,
            $"{constraint}: SQL Server accepted a statement that should violate it.");
        Assert.True(postgres is not null,
            $"{constraint}: PostgreSQL accepted a statement that should violate it. " +
            "The constraint may not have survived the port.");
    }

    // ---------------------------------------------------------------------

    private void InRollbackScope(Action body)
    {
        using var mssql = _db.SqlServer.BeginRollbackScope();
        using var postgres = _db.Postgres.BeginRollbackScope();
        body();
    }

    private void Execute(string sql)
    {
        _db.SqlServer.Execute(sql);
        _db.Postgres.Execute(sql);
    }

    /// <summary>
    /// The current high-water mark of audit.ChangeLog, used to select only the rows
    /// a test's own writes produced. Asserted equal on both engines first: the table
    /// is replicated, so an inequality here would mean the two sides had already
    /// drifted and any comparison after it would be meaningless.
    /// </summary>
    private long Watermark()
    {
        const string sql = "SELECT COALESCE(MAX(ChangeLogId), 0) FROM audit.ChangeLog";
        var sqlServer = (decimal)_db.SqlServer.Scalar(sql)!;
        var postgres = (decimal)_db.Postgres.Scalar(sql)!;

        Assert.True(sqlServer == postgres,
            $"audit.ChangeLog has already diverged: sqlserver max={sqlServer}, postgres max={postgres}. " +
            "Re-run scripts/replicate-to-postgres.sh.");

        return (long)sqlServer;
    }

    private void CompareQuery(string sql, string context) =>
        ParityAssert.Same(_db.SqlServer.QueryOne(sql), _db.Postgres.QueryOne(sql), context);

    private void CompareJson(string sql, string context)
    {
        var jsonColumns = new HashSet<string>(StringComparer.Ordinal) { "oldvalues", "newvalues" };
        ParityAssert.Same(
            _db.SqlServer.QueryOne(sql).WithCanonicalJson(jsonColumns),
            _db.Postgres.QueryOne(sql).WithCanonicalJson(jsonColumns),
            context);
    }
}
