using System.Buffers.Binary;
using System.Text;
using DbParity.Core.Targets;
using Microsoft.Data.SqlClient;
using Npgsql;
using NpgsqlTypes;

namespace DbParity.Core.Fixture;

/// <summary>
/// Copies the sample data from SQL Server into PostgreSQL, so both engines answer
/// the comparison queries over identical inputs.
///
/// SQL Server is the source of truth: db/sqlserver/021_seed_sample_data.sql authors
/// the data, and there is no PostgreSQL seed to drift from it.
///
/// Two things are deliberately NOT copied, and both leave real signal behind:
///
///   Reference data  ref.* (12 tables) is seeded independently on each engine by
///                   each side's own 020_seed_reference_data.sql. Comparing it is
///                   therefore a genuine test of the ported seed rather than a
///                   tautology. This is safe only because every foreign key into
///                   ref uses a natural key -- SchemaParityTests asserts that, and
///                   if it ever stops being true this replicator becomes unsound.
///
///   Generated cols  PostgreSQL rejects a supplied value for a GENERATED ALWAYS
///                   ... STORED column, so the 18 computed columns are omitted and
///                   recomputed by PostgreSQL. Comparing them afterwards tests that
///                   the ported expressions agree with the T-SQL originals.
/// </summary>
public sealed class FixtureReplicator
{
    /// <summary>The schemas holding sample data. <c>ref</c> and <c>util</c> are excluded by design.</summary>
    public static readonly string[] SampleSchemas = ["client", "tax", "acct", "payroll", "audit"];

    private readonly SqlConnection _source;
    private readonly NpgsqlConnection _target;

    public FixtureReplicator(SqlConnection source, NpgsqlConnection target)
    {
        _source = source;
        _target = target;
    }

    public static FixtureReplicator Connect()
    {
        var source = new SqlConnection(TargetConfig.SqlServerConnectionString);
        source.Open();
        var target = new NpgsqlConnection(TargetConfig.PostgresConnectionString);
        target.Open();
        return new FixtureReplicator(source, target);
    }

    public ReplicationReport Run(Action<string>? log = null)
    {
        log ??= _ => { };

        var tables = ReadTargetTables();
        if (tables.Count == 0)
        {
            throw new InvalidOperationException(
                "No sample tables found in PostgreSQL. Apply the port first: scripts/apply-postgres.sh");
        }

        // replica mode disables foreign-key enforcement AND user triggers. Both
        // matter: the first lets tables load in any order, and the second stops
        // client.tr_Client_Audit and tax.tr_T1Return_StatusHistory from firing and
        // manufacturing audit rows that the source does not have.
        Execute("SET session_replication_role = replica");
        try
        {
            var qualified = tables.Select(t => $"{Quote(t.Schema)}.{Quote(t.Name)}");
            Execute($"TRUNCATE {string.Join(", ", qualified)} CASCADE");

            var copied = new Dictionary<string, long>(StringComparer.Ordinal);
            foreach (var table in tables)
            {
                var rows = CopyTable(table);
                copied[table.Key] = rows;
                log($"  {table.Key,-34} {rows,7:N0}");
            }

            SyncSeedMutatedReferenceRows();
            ResyncSequences(tables);
            RefreshMaterializedViews();
            return Verify(tables, copied);
        }
        finally
        {
            Execute("SET session_replication_role = origin");
        }
    }

    /// <summary>
    /// Streams one table across. Reading and writing are interleaved, so memory
    /// stays flat regardless of how much the seed script grows.
    /// </summary>
    private long CopyTable(TargetTable table)
    {
        var writable = table.Columns.Where(c => !c.IsGenerated).ToArray();
        var columnList = string.Join(", ", writable.Select(c => Quote(c.Name)));

        // Identifiers are lowercase here but SQL Server's collation is
        // case-insensitive, so they bind unchanged on the source side.
        var order = table.IdentityColumn is null ? "" : $" ORDER BY [{table.IdentityColumn}]";
        var selectList = string.Join(", ", writable.Select(c => $"[{c.Name}]"));
        var sourceSql = $"SELECT {selectList} FROM [{table.Schema}].[{table.Name}]{order}";

        using var read = new SqlCommand(sourceSql, _source) { CommandTimeout = 180 };
        using var reader = read.ExecuteReader();

        var copySql = $"COPY {Quote(table.Schema)}.{Quote(table.Name)} ({columnList}) FROM STDIN (FORMAT BINARY)";
        using var writer = _target.BeginBinaryImport(copySql);

        long rows = 0;
        while (reader.Read())
        {
            writer.StartRow();
            for (var i = 0; i < writable.Length; i++)
            {
                WriteValue(writer, reader.IsDBNull(i) ? null : reader.GetValue(i), writable[i], table);
            }
            rows++;
        }

        writer.Complete();
        return rows;
    }

    /// <summary>
    /// Writes one value in the target column's own type. The mapping is explicit and
    /// closed: an unmapped PostgreSQL type throws rather than being guessed at, so a
    /// future column that this replicator does not understand fails loudly here
    /// instead of silently landing wrong data for the tests to bless.
    /// </summary>
    private static void WriteValue(NpgsqlBinaryImporter writer, object? value, TargetColumn column, TargetTable table)
    {
        if (value is null)
        {
            writer.WriteNull();
            return;
        }

        switch (column.TypeName)
        {
            case "int2":
                // SQL Server tinyint arrives as byte, smallint as short.
                writer.Write(Convert.ToInt16(value), NpgsqlDbType.Smallint);
                break;

            case "int4":
                writer.Write(Convert.ToInt32(value), NpgsqlDbType.Integer);
                break;

            case "int8":
                // client.Client.RowVersion is SQL Server's 8-byte rowversion and a
                // bigint here. It is big-endian and monotonic, so this preserves the
                // ordering the source assigned. The column is excluded from value
                // comparison by policy; what matters is that it is NOT NULL and
                // ordered the same way.
                writer.Write(
                    value is byte[] bytes
                        ? BinaryPrimitives.ReadInt64BigEndian(PadTo8(bytes))
                        : Convert.ToInt64(value),
                    NpgsqlDbType.Bigint);
                break;

            case "numeric":
                // SQL Server bit arrives as bool; the port maps bit to numeric(1,0).
                writer.Write(
                    value is bool flag ? (flag ? 1m : 0m) : Convert.ToDecimal(value),
                    NpgsqlDbType.Numeric);
                break;

            case "varchar":
                writer.Write(Convert.ToString(value) ?? "", NpgsqlDbType.Varchar);
                break;

            case "bpchar":
                writer.Write(Convert.ToString(value) ?? "", NpgsqlDbType.Char);
                break;

            case "text":
                writer.Write(Convert.ToString(value) ?? "", NpgsqlDbType.Text);
                break;

            case "jsonb":
                // Stored as NVARCHAR on SQL Server. jsonb reparses and normalizes it,
                // so the two sides are equal as JSON but not as text -- which is why
                // the cases comparing these columns compare them as JSON.
                writer.Write(Convert.ToString(value) ?? "null", NpgsqlDbType.Jsonb);
                break;

            case "date":
                writer.Write(DateOnly.FromDateTime(Convert.ToDateTime(value)), NpgsqlDbType.Date);
                break;

            case "timestamp":
                writer.Write(Convert.ToDateTime(value), NpgsqlDbType.Timestamp);
                break;

            default:
                throw new NotSupportedException(
                    $"No replication mapping for PostgreSQL type '{column.TypeName}' " +
                    $"on {table.Key}.{column.Name}. Add one to FixtureReplicator.WriteValue.");
        }
    }

    private static byte[] PadTo8(byte[] bytes)
    {
        if (bytes.Length == 8) return bytes;
        var padded = new byte[8];
        Array.Copy(bytes, 0, padded, 8 - bytes.Length, Math.Min(8, bytes.Length));
        return padded;
    }

    /// <summary>
    /// Moves every sequence past the values just loaded, so the procedures under
    /// test allocate fresh keys instead of colliding with replicated rows.
    /// </summary>
    private void ResyncSequences(IReadOnlyList<TargetTable> tables)
    {
        foreach (var table in tables.Where(t => t.IdentityColumn is not null))
        {
            Execute($"""
                SELECT setval(
                    pg_get_serial_sequence('{table.Schema}.{table.Name}', '{table.IdentityColumn}'),
                    COALESCE((SELECT MAX({Quote(table.IdentityColumn!)}) FROM {Quote(table.Schema)}.{Quote(table.Name)}), 1),
                    (SELECT MAX({Quote(table.IdentityColumn!)}) FROM {Quote(table.Schema)}.{Quote(table.Name)}) IS NOT NULL)
                """);
        }

        // acct.seq_invoicenumber is a standalone sequence on both engines and hands
        // out invoice numbers; it has to continue from where SQL Server left off or
        // usp_GenerateInvoice would reissue numbers the replicated rows already use.
        var sourceValue = ScalarOnSource(
            "SELECT CONVERT(bigint, current_value) FROM sys.sequences WHERE name = 'seq_InvoiceNumber'");
        if (sourceValue is not null)
        {
            Execute($"SELECT setval('acct.seq_invoicenumber', {Convert.ToInt64(sourceValue)}, true)");
        }

        // client.seq_rowversion backs the ROWVERSION emulation, which the trigger
        // maintains; it must clear the replicated values.
        Execute("""
            SELECT setval('client.seq_rowversion',
                          COALESCE((SELECT MAX(rowversion) FROM client.client), 1),
                          (SELECT MAX(rowversion) FROM client.client) IS NOT NULL)
            """);
    }

    /// <summary>
    /// Carries across the one reference row that the sample-data script mutates.
    ///
    /// db/sqlserver/021_seed_sample_data.sql ends by locking the 2023 tax year
    /// (`UPDATE ref.TaxYear SET IsLocked = 1`), which it does last, after 2023's
    /// returns have been calculated. That state is not part of
    /// 020_seed_reference_data.sql, so PostgreSQL -- which is only ever given the
    /// reference seed -- would leave 2023 unlocked and tax.usp_CalculateT1 would
    /// not raise error 50011 there. The suite found this on its first run.
    ///
    /// It is an UPDATE rather than a truncate-and-reload because ref.TaxYear is
    /// referenced by ref.TaxBracket, ref.NonRefundableCredit and ref.PayrollRate,
    /// none of which are replicated: TRUNCATE ... CASCADE would empty them and
    /// nothing would put them back.
    ///
    /// Everything else in ref.* stays independently seeded on each engine, so
    /// comparing it remains a real test of the ported seed.
    /// </summary>
    private void SyncSeedMutatedReferenceRows()
    {
        var locked = new List<short>();
        using (var command = new SqlCommand(
                   "SELECT TaxYear FROM ref.TaxYear WHERE IsLocked = 1 ORDER BY TaxYear", _source))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read()) locked.Add(reader.GetInt16(0));
        }

        using var update = new NpgsqlCommand(
            "UPDATE ref.taxyear SET islocked = CASE WHEN taxyear = ANY(@locked) THEN 1 ELSE 0 END",
            _target);
        update.Parameters.AddWithValue("locked", locked.ToArray());
        update.ExecuteNonQuery();
    }

    /// <summary>
    /// SQL Server maintains acct.vw_FiscalYearRevenue automatically -- it is an
    /// indexed view. PostgreSQL's equivalent is a materialized view, which does not
    /// track its base tables, so it is stale the moment the load finishes and has
    /// to be refreshed here. Skipping this would make the view comparison fail for
    /// a reason that has nothing to do with the port.
    /// </summary>
    private void RefreshMaterializedViews()
    {
        var views = new List<string>();

        using (var command = new NpgsqlCommand(
                   """
                   SELECT n.nspname, c.relname
                   FROM pg_class c
                   JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE c.relkind = 'm' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
                   ORDER BY 1, 2
                   """, _target))
        using (var reader = command.ExecuteReader())
        {
            while (reader.Read())
            {
                views.Add($"{Quote(reader.GetString(0))}.{Quote(reader.GetString(1))}");
            }
        }

        foreach (var view in views)
        {
            Execute($"REFRESH MATERIALIZED VIEW {view}");
        }
    }

    /// <summary>
    /// The gate. A short load that still produced green tests would be the worst
    /// outcome available here, so every table's count is checked against the source
    /// before any test is allowed to run.
    /// </summary>
    private ReplicationReport Verify(IReadOnlyList<TargetTable> tables, IReadOnlyDictionary<string, long> copied)
    {
        var mismatches = new List<string>();
        var counts = new Dictionary<string, long>(StringComparer.Ordinal);

        foreach (var table in tables)
        {
            var sourceCount = Convert.ToInt64(
                ScalarOnSource($"SELECT COUNT_BIG(*) FROM [{table.Schema}].[{table.Name}]"));
            var targetCount = Convert.ToInt64(
                ScalarOnTarget($"SELECT COUNT(*) FROM {Quote(table.Schema)}.{Quote(table.Name)}"));

            counts[table.Key] = targetCount;

            if (sourceCount != targetCount || copied[table.Key] != sourceCount)
            {
                mismatches.Add(
                    $"  {table.Key}: sqlserver={sourceCount}, copied={copied[table.Key]}, postgres={targetCount}");
            }
        }

        if (mismatches.Count > 0)
        {
            throw new InvalidOperationException(
                "Replication did not land every row:\n" + string.Join('\n', mismatches));
        }

        return new ReplicationReport(counts);
    }

    /// <summary>
    /// Reads the shape of the target tables from the PostgreSQL catalog rather than
    /// assuming it, so adding a column to the schema does not silently skip it.
    /// </summary>
    private List<TargetTable> ReadTargetTables()
    {
        const string sql = """
            SELECT n.nspname                                      AS schema_name,
                   c.relname                                      AS table_name,
                   a.attname                                      AS column_name,
                   t.typname                                      AS type_name,
                   a.attgenerated = 's'                           AS is_generated,
                   a.attidentity IN ('a', 'd')                    AS is_identity,
                   a.attnum                                       AS ordinal
            FROM pg_attribute a
            JOIN pg_class c     ON c.oid = a.attrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_type t      ON t.oid = a.atttypid
            WHERE c.relkind = 'r'
              AND n.nspname = ANY(@schemas)
              AND a.attnum > 0
              AND NOT a.attisdropped
            ORDER BY n.nspname, c.relname, a.attnum
            """;

        using var command = new NpgsqlCommand(sql, _target);
        command.Parameters.AddWithValue("schemas", SampleSchemas);

        var byTable = new Dictionary<string, TargetTable>(StringComparer.Ordinal);
        var order = new List<TargetTable>();

        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var schema = reader.GetString(0);
            var name = reader.GetString(1);
            var key = $"{schema}.{name}";

            if (!byTable.TryGetValue(key, out var table))
            {
                table = new TargetTable(schema, name);
                byTable[key] = table;
                order.Add(table);
            }

            var column = new TargetColumn(reader.GetString(2), reader.GetString(3), reader.GetBoolean(4));
            table.Columns.Add(column);
            if (reader.GetBoolean(5)) table.IdentityColumn = column.Name;
        }

        return order;
    }

    private void Execute(string sql)
    {
        using var command = new NpgsqlCommand(sql, _target) { CommandTimeout = 180 };
        command.ExecuteNonQuery();
    }

    private object? ScalarOnTarget(string sql)
    {
        using var command = new NpgsqlCommand(sql, _target) { CommandTimeout = 180 };
        var value = command.ExecuteScalar();
        return value is DBNull ? null : value;
    }

    private object? ScalarOnSource(string sql)
    {
        using var command = new SqlCommand(sql, _source) { CommandTimeout = 180 };
        var value = command.ExecuteScalar();
        return value is DBNull ? null : value;
    }

    /// <summary>Double-quotes a PostgreSQL identifier.</summary>
    private static string Quote(string identifier) => '"' + identifier.Replace("\"", "\"\"") + '"';

    public void Dispose()
    {
        _source.Dispose();
        _target.Dispose();
    }

    private sealed class TargetTable(string schema, string name)
    {
        public string Schema { get; } = schema;
        public string Name { get; } = name;
        public string Key => $"{Schema}.{Name}";
        public List<TargetColumn> Columns { get; } = [];
        public string? IdentityColumn { get; set; }
    }

    private sealed record TargetColumn(string Name, string TypeName, bool IsGenerated);
}

/// <summary>Per-table row counts after a successful replication.</summary>
public sealed class ReplicationReport
{
    public ReplicationReport(IReadOnlyDictionary<string, long> rowCounts) => RowCounts = rowCounts;

    public IReadOnlyDictionary<string, long> RowCounts { get; }

    public long TotalRows => RowCounts.Values.Sum();

    public override string ToString()
    {
        var text = new StringBuilder();
        foreach (var (table, count) in RowCounts.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            text.AppendLine($"  {table,-34} {count,7:N0}");
        }
        text.AppendLine($"  {"TOTAL",-34} {TotalRows,7:N0}");
        return text.ToString();
    }
}
