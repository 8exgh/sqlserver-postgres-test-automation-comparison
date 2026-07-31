using DbParity.Core.Results;
using DbParity.Tests.Cases;
using Xunit;

namespace DbParity.Tests;

/// <summary>
/// The data-driven core of the suite: every .sql file under cases/ becomes one
/// named test that runs the same query against both engines and compares the
/// results cell by cell.
/// </summary>
[Collection(ParityCollection.Name)]
public sealed class QueryParityTests
{
    private static readonly IReadOnlyList<CaseFile> AllCases = CaseFile.Discover();

    private static readonly IReadOnlyDictionary<string, CaseFile> ById =
        AllCases.ToDictionary(c => c.Id, StringComparer.Ordinal);

    private readonly ParityFixture _db;

    public QueryParityTests(ParityFixture db) => _db = db;

    /// <summary>Case ids, which xUnit renders as the test name.</summary>
    public static TheoryData<string> CaseIds
    {
        get
        {
            var data = new TheoryData<string>();
            foreach (var caseFile in AllCases) data.Add(caseFile.Id);
            return data;
        }
    }

    [Theory]
    [MemberData(nameof(CaseIds))]
    public void Engines_agree(string caseId)
    {
        var testCase = ById[caseId];

        var (sqlServer, sqlServerDropped) = Prepare(_db.SqlServer.QueryOne(testCase.SqlServerSql), testCase);
        var (postgres, postgresDropped) = Prepare(_db.Postgres.QueryOne(testCase.PostgresSql), testCase);

        DroppedByDivergencePolicy[caseId] = sqlServerDropped + postgresDropped;

        if (!testCase.AllowEmpty)
        {
            ParityAssert.NotVacuous(sqlServer, postgres, $"Case '{testCase.Name}'");
        }

        ParityAssert.Same(sqlServer, postgres, testCase.Name);
    }

    /// <summary>
    /// Applies the case's comparison policy. Order matters: columns are dropped
    /// before JSON is canonicalized (no point parsing a column nobody compares),
    /// and the client-side sort runs last so it sees the values that will actually
    /// be compared.
    /// </summary>
    private static (ResultSet Prepared, int Dropped) Prepare(ResultSet raw, CaseFile testCase)
    {
        var (filtered, dropped) = raw.WithoutRows(
            testCase.DivergenceKey,
            DivergencePolicy.Instance.ForCase(testCase.Id));

        var prepared = filtered
            .WithoutColumns(testCase.ExcludedColumns())
            .WithCanonicalJson(testCase.JsonColumns);

        return (testCase.SortClientSide ? prepared.SortedOrdinally() : prepared, dropped);
    }

    /// <summary>
    /// How many rows each case dropped under the divergence policy this run, so
    /// <see cref="Every_accepted_divergence_still_applies"/> can tell a live
    /// exception from a stale one.
    /// </summary>
    private static readonly Dictionary<string, int> DroppedByDivergencePolicy = new(StringComparer.Ordinal);

    /// <summary>
    /// An allowlist entry that no longer matches anything is worse than no entry:
    /// it documents a difference that has since been fixed or renamed, and it would
    /// silently swallow a future row that happens to take the same key.
    /// </summary>
    [Fact]
    public void Every_accepted_divergence_still_applies()
    {
        foreach (var (caseId, _) in DivergencePolicy.Instance.All.DistinctBy(e => e.CaseId))
        {
            Assert.True(ById.ContainsKey(caseId),
                $"known-schema-divergences.txt names case '{caseId}', which does not exist.");

            // Force the case to run so its drop count is recorded.
            if (!DroppedByDivergencePolicy.ContainsKey(caseId)) Engines_agree(caseId);

            Assert.True(DroppedByDivergencePolicy[caseId] > 0,
                $"Case '{caseId}' has entries in known-schema-divergences.txt but dropped no rows. " +
                "The entries are stale -- remove them.");
        }
    }

    /// <summary>
    /// Guards the case corpus itself. A typo in a directive, an empty cases/
    /// directory, or a build that failed to copy the files would otherwise show up
    /// as a suspiciously clean run.
    /// </summary>
    [Fact]
    public void Case_corpus_is_present_and_well_formed()
    {
        Assert.NotEmpty(AllCases);

        var unnamed = AllCases.Where(c => string.IsNullOrWhiteSpace(c.Name)).Select(c => c.Id).ToArray();
        Assert.True(unnamed.Length == 0, "Cases without a name: " + string.Join(", ", unnamed));

        var uncategorized = AllCases.Where(c => c.Category == "uncategorized").Select(c => c.Id).ToArray();
        Assert.True(uncategorized.Length == 0,
            "Cases without an @category: " + string.Join(", ", uncategorized));
    }
}
