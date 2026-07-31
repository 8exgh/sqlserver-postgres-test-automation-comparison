using DbParity.Core.Results;
using Xunit;
using Xunit.Sdk;

namespace DbParity.Tests;

/// <summary>
/// Assertions that carry the comparer's full report into the failure message.
///
/// <c>Assert.Null(diff)</c> truncates, which throws away the cell-level detail that
/// is the entire reason the comparer produces it.
/// </summary>
public static class ParityAssert
{
    /// <summary>Asserts the two result sets are identical, reporting every difference found.</summary>
    public static void Same(ResultSet sqlServer, ResultSet postgres, string? context = null)
    {
        var report = ResultSetComparer.Compare(sqlServer, postgres);
        if (report is null) return;

        var heading = context is null ? "Result sets differ" : $"Result sets differ ({context})";
        throw new XunitException($"{heading}\n{report}");
    }

    /// <summary>
    /// Asserts the query returned something. A case that is empty on both sides
    /// compares equal and passes while testing nothing, which is worse than having
    /// no case at all -- so emptiness has to be opted into explicitly.
    /// </summary>
    public static void NotVacuous(ResultSet sqlServer, ResultSet postgres, string context)
    {
        if (sqlServer.Rows.Count > 0 || postgres.Rows.Count > 0) return;

        throw new XunitException(
            $"{context} returned no rows on either engine, so it asserts nothing. " +
            "Fix the case, or mark it '-- @allow-empty' if emptiness is the point.");
    }

    /// <summary>Asserts both engines raised the same error code.</summary>
    public static void SameError(
        Core.Targets.DbError? sqlServer,
        Core.Targets.DbError? postgres,
        int expected,
        string context)
    {
        if (sqlServer is null && postgres is null)
        {
            throw new XunitException($"{context}: expected error {expected}, but both engines succeeded.");
        }

        if (sqlServer is null)
        {
            throw new XunitException(
                $"{context}: sqlserver succeeded but postgres raised {postgres}.");
        }

        if (postgres is null)
        {
            throw new XunitException(
                $"{context}: postgres succeeded but sqlserver raised {sqlServer}.");
        }

        Assert.Multiple(
            () => Assert.True(sqlServer.Number == expected,
                $"{context}: sqlserver raised {sqlServer.Number}, expected {expected}. {sqlServer.Message}"),
            () => Assert.True(postgres.Number == expected,
                $"{context}: postgres raised SQLSTATE '{postgres.SqlState}', expected '{expected}'. {postgres.Message}"));
    }
}
