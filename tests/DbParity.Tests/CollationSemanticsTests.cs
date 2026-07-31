using Xunit;

namespace DbParity.Tests;

/// <summary>
/// Where the two engines genuinely behave differently, pinned down in code.
///
/// SQL Server's database collation is SQL_Latin1_General_CP1_CI_AS -- case
/// insensitive -- and the PostgreSQL database is en_US.utf8, which is case
/// sensitive for comparison. Application code that relies on a case-insensitive
/// WHERE keeps working right up until it is pointed at PostgreSQL, and then
/// quietly returns nothing. That is the single most likely way this migration
/// breaks something in production without anyone noticing.
///
/// These tests assert the divergence rather than hiding it. If someone later
/// gives PostgreSQL a case-insensitive collation or moves the columns to citext,
/// they start failing -- which is the point: the change should be deliberate and
/// visible, not discovered.
/// </summary>
[Collection(ParityCollection.Name)]
public sealed class CollationSemanticsTests
{
    private readonly ParityFixture _db;

    public CollationSemanticsTests(ParityFixture db) => _db = db;

    [Fact]
    public void Equality_is_case_insensitive_on_sql_server_only()
    {
        // ClientCode is seeded upper-case ('IND-0016'), so the lower-case literal
        // matches on SQL Server and nowhere else.
        const string sql = "SELECT COUNT(*) FROM client.Client WHERE ClientCode = 'ind-0016'";

        Assert.Equal(1m, _db.SqlServer.Scalar(sql));
        Assert.Equal(0m, _db.Postgres.Scalar(sql));
    }

    [Fact]
    public void Like_is_case_insensitive_on_sql_server_only()
    {
        const string sql = "SELECT COUNT(*) FROM client.Client WHERE ClientCode LIKE 'ind%'";

        var sqlServer = (decimal)_db.SqlServer.Scalar(sql)!;
        var postgres = (decimal)_db.Postgres.Scalar(sql)!;

        Assert.True(sqlServer > 0, "Expected the seeded IND-* client codes to match on SQL Server.");
        Assert.Equal(0m, postgres);

        // The equivalent PostgreSQL spelling. ILIKE has no SQL Server counterpart,
        // so a port that needs case-insensitive matching has to change the query,
        // not just the connection string.
        Assert.Equal(sqlServer,
            (decimal)_db.Postgres.Scalar("SELECT COUNT(*) FROM client.client WHERE clientcode ILIKE 'ind%'")!);
    }

    [Fact]
    public void Text_ordering_agrees_but_only_because_of_the_chosen_collation()
    {
        // en_US.utf8 orders case-insensitively for this data, so ORDER BY on text
        // happens to agree with CI_AS today. It is asserted so that a move to the
        // C collation -- which orders by byte value and would put every upper-case
        // letter before every lower-case one -- shows up here rather than as a
        // mystery reordering in a report.
        const string sql = "SELECT DisplayName FROM client.Client ORDER BY DisplayName, ClientId";

        var sqlServer = _db.SqlServer.QueryOne(sql);
        var postgres = _db.Postgres.QueryOne(sql);

        Assert.NotEmpty(sqlServer.Rows);
        ParityAssert.Same(sqlServer, postgres, "ORDER BY DisplayName");

        var collation = (string)_db.Postgres.Scalar(
            "SELECT datcollate FROM pg_database WHERE datname = current_database()")!;
        Assert.True(collation.StartsWith("en_US", StringComparison.Ordinal),
            $"This test's premise is the en_US collation; the database now uses '{collation}'. " +
            "Re-check whether text ordering still matches SQL Server's CI_AS.");
    }

    [Fact]
    public void Sql_server_treats_trailing_spaces_as_insignificant_in_comparison()
    {
        // ANSI padding: SQL Server's = ignores trailing spaces, PostgreSQL's does
        // not for varchar. Another silent behaviour change for any code comparing
        // user-entered text.
        const string sql = "SELECT COUNT(*) FROM client.Client WHERE ClientCode = 'IND-0016   '";

        Assert.Equal(1m, _db.SqlServer.Scalar(sql));
        Assert.Equal(0m, _db.Postgres.Scalar(sql));
    }
}
