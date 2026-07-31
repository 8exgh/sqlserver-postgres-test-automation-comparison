using DbParity.Core.Targets;
using DbParity.Tests.Cases;
using Xunit;

namespace DbParity.Tests;

/// <summary>
/// Assertions that are not comparisons: they check that the premises the rest of
/// the suite relies on are still true.
///
/// Every exclusion in policy/excluded-columns.txt is a small hole in the
/// comparison. These tests make sure each hole stays the size it was argued for.
/// </summary>
[Collection(ParityCollection.Name)]
public sealed class SchemaPolicyTests
{
    private readonly ParityFixture _db;

    public SchemaPolicyTests(ParityFixture db) => _db = db;

    /// <summary>
    /// The premise that makes replication sound.
    ///
    /// ref.* is not replicated, so its surrogate identity values differ between the
    /// two databases -- ref.TaxBracketId 39 on SQL Server is 34 on PostgreSQL. That
    /// is harmless only for as long as nothing points at those columns. If a
    /// foreign key is ever added to one, replicating the sample tables verbatim
    /// would silently attach rows to the wrong reference row, and the suite would
    /// go on passing.
    /// </summary>
    [Theory]
    [InlineData("sqlserver")]
    [InlineData("postgres")]
    public void No_foreign_key_targets_a_ref_surrogate_key(string engine)
    {
        var surrogates = ExclusionPolicy.Instance.QualifiedColumns
            .Where(c => c.StartsWith("ref.", StringComparison.Ordinal))
            .ToHashSet(StringComparer.Ordinal);

        Assert.NotEmpty(surrogates);

        var target = Target(engine);
        var referenced = target.QueryOne(engine == "sqlserver"
            ? """
              SELECT LOWER(rs.name) + '.' + LOWER(CONVERT(varchar(128), rt.name)) + '.'
                   + LOWER(CONVERT(varchar(128), rc.name)) AS Target
              FROM sys.foreign_key_columns fkc
              JOIN sys.tables rt   ON rt.object_id = fkc.referenced_object_id
              JOIN sys.schemas rs  ON rs.schema_id = rt.schema_id
              JOIN sys.columns rc  ON rc.object_id = fkc.referenced_object_id
                                  AND rc.column_id = fkc.referenced_column_id
              WHERE rs.name = 'ref'
              """
            : """
              SELECT DISTINCT rn.nspname || '.' || rc.relname || '.' || ra.attname AS target
              FROM pg_constraint con
              JOIN pg_class rc     ON rc.oid = con.confrelid
              JOIN pg_namespace rn ON rn.oid = rc.relnamespace
              JOIN unnest(con.confkey) AS k(attnum) ON true
              JOIN pg_attribute ra ON ra.attrelid = con.confrelid AND ra.attnum = k.attnum
              WHERE con.contype = 'f' AND rn.nspname = 'ref'
              """);

        var offending = referenced.Rows
            .Select(r => (string)r[0]!)
            .Where(surrogates.Contains)
            .Distinct()
            .ToArray();

        Assert.True(offending.Length == 0,
            $"[{engine}] a foreign key now targets a ref surrogate key: {string.Join(", ", offending)}. " +
            "Those columns are excluded from comparison because ref.* is seeded independently on " +
            "each engine and the identity values differ -- so replication would attach rows to the " +
            "wrong reference row. Either replicate the ref table or key the relationship naturally.");
    }

    /// <summary>
    /// A stale exclusion is an invisible hole: it names a column that no longer
    /// exists, so it silently excludes nothing while still reading like a
    /// considered decision.
    /// </summary>
    [Theory]
    [InlineData("sqlserver")]
    [InlineData("postgres")]
    public void Every_excluded_column_still_exists(string engine)
    {
        var target = Target(engine);
        var existing = target.QueryOne(engine == "sqlserver"
            ? """
              SELECT LOWER(s.name) + '.' + LOWER(CONVERT(varchar(128), t.name)) + '.'
                   + LOWER(CONVERT(varchar(128), c.name)) AS Qualified
              FROM sys.columns c
              JOIN sys.tables t  ON t.object_id = c.object_id
              JOIN sys.schemas s ON s.schema_id = t.schema_id
              """
            : """
              SELECT n.nspname || '.' || c.relname || '.' || a.attname AS qualified
              FROM pg_attribute a
              JOIN pg_class c     ON c.oid = a.attrelid
              JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
              """)
            .Rows.Select(r => (string)r[0]!)
            .ToHashSet(StringComparer.Ordinal);

        var missing = ExclusionPolicy.Instance.QualifiedColumns
            .Where(c => !existing.Contains(c))
            .ToArray();

        Assert.True(missing.Length == 0,
            $"[{engine}] excluded-columns.txt names columns that do not exist: " +
            string.Join(", ", missing) + ". Remove the stale entries.");
    }

    /// <summary>
    /// client.Client.RowVersion is excluded because the two types cannot hold the
    /// same value, not because the column is unimportant. What it must still do is
    /// exist, be NOT NULL, and be strictly ordered the way the source assigned it --
    /// the replicator converts SQL Server's big-endian counter to preserve exactly
    /// that. Optimistic-concurrency checks depend on the ordering, not the value.
    /// </summary>
    [Fact]
    public void Rowversion_ordering_survives_the_conversion()
    {
        const string sql = """
            SELECT ClientId
            FROM client.Client
            ORDER BY RowVersion, ClientId
            """;

        var mssql = _db.SqlServer.QueryOne(sql);
        var postgres = _db.Postgres.QueryOne(sql);

        Assert.NotEmpty(mssql.Rows);
        ParityAssert.Same(mssql, postgres, "client order by RowVersion");

        Assert.Equal(0m, _db.Postgres.Scalar("SELECT COUNT(*) FROM client.client WHERE rowversion IS NULL"));
        Assert.Equal(
            _db.SqlServer.Scalar("SELECT COUNT(DISTINCT CONVERT(bigint, RowVersion)) FROM client.Client"),
            _db.Postgres.Scalar("SELECT COUNT(DISTINCT rowversion) FROM client.client"));
    }

    private DbTarget Target(string engine) =>
        engine == "sqlserver" ? _db.SqlServer : _db.Postgres;
}
