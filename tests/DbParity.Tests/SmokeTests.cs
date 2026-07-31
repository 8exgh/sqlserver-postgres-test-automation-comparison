using DbParity.Core.Results;
using Xunit;

namespace DbParity.Tests;

/// <summary>
/// The premise the whole suite rests on: one SQL string, sent unchanged to both
/// engines, binds and returns the same data.
///
/// It holds because SQL Server's database collation is SQL_Latin1_General_CP1_CI_AS
/// (so identifiers resolve case-insensitively) and every PostgreSQL object was
/// created unquoted (so it is lowercase and also resolves case-insensitively).
/// If either of those ever changes, these tests fail first and explain why every
/// other case in the suite has started failing too.
/// </summary>
[Collection(ParityCollection.Name)]
public sealed class SmokeTests
{
    private readonly ParityFixture _db;

    public SmokeTests(ParityFixture db) => _db = db;

    [Fact]
    public void Both_engines_are_reachable()
    {
        Assert.Equal(1m, _db.SqlServer.Scalar("SELECT 1"));
        Assert.Equal(1m, _db.Postgres.Scalar("SELECT 1"));
    }

    [Fact]
    public void Sql_server_collation_is_case_insensitive()
    {
        // The whole shared-SQL premise depends on this.
        var collation = _db.SqlServer.Scalar("SELECT CONVERT(nvarchar(128), DATABASEPROPERTYEX(DB_NAME(), 'Collation'))");
        Assert.Contains("_CI_", Assert.IsType<string>(collation));
    }

    [Fact]
    public void Mixed_case_identifiers_bind_on_both_engines()
    {
        // Ordered by the natural key, not TaxBracketId. The two databases are seeded
        // independently, so their identity values are assigned in different orders
        // and do not line up -- see ReferenceKeyTests, which pins down why that is
        // safe (nothing references a ref surrogate key).
        const string sql = """
            SELECT TaxYear, JurisdictionCode, Ordinal, LowerBound, UpperBound, Rate
            FROM ref.TaxBracket
            WHERE JurisdictionCode = 'CA' AND TaxYear = 2024
            ORDER BY TaxYear, JurisdictionCode, Ordinal
            """;

        var mssql = _db.SqlServer.QueryOne(sql);
        var pg = _db.Postgres.QueryOne(sql);

        Assert.NotEmpty(mssql.Rows);
        ParityAssert.Same(mssql, pg);
    }

    [Fact]
    public void Scalar_functions_agree()
    {
        const string sql = "SELECT tax.fn_FederalTax(2024, 100000)";
        Assert.Equal(17427.32m, _db.SqlServer.Scalar(sql));
        Assert.Equal(17427.32m, _db.Postgres.Scalar(sql));
    }

    [Fact]
    public void Table_valued_functions_agree()
    {
        const string sql = "SELECT * FROM tax.fn_TaxBracketBreakdown('CA', 2024, 100000)";

        var mssql = _db.SqlServer.QueryOne(sql);
        var pg = _db.Postgres.QueryOne(sql);

        Assert.NotEmpty(mssql.Rows);
        ParityAssert.Same(mssql, pg);
    }
}
