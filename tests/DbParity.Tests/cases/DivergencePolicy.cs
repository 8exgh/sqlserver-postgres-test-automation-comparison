namespace DbParity.Tests.Cases;

/// <summary>
/// Rows a case is allowed to see on one engine only, because the difference is
/// correct. Read from policy/known-schema-divergences.txt.
///
/// Every entry must carry a reason, and the file is small on purpose: an
/// allowlist that grows without argument stops being a record of decisions and
/// becomes a way to make the suite quiet.
/// </summary>
public sealed class DivergencePolicy
{
    private readonly IReadOnlyDictionary<string, IReadOnlySet<string>> _byCase;

    private DivergencePolicy(IReadOnlyDictionary<string, IReadOnlySet<string>> byCase) => _byCase = byCase;

    public static DivergencePolicy Instance { get; } = Load();

    /// <summary>Row keys accepted as divergent for one case; empty when there are none.</summary>
    public IReadOnlySet<string> ForCase(string caseId) =>
        _byCase.TryGetValue(caseId, out var keys) ? keys : new HashSet<string>();

    /// <summary>All entries, for the test that asserts none has gone stale.</summary>
    public IEnumerable<(string CaseId, string RowKey)> All =>
        _byCase.SelectMany(pair => pair.Value.Select(key => (pair.Key, key)));

    private static DivergencePolicy Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "policy", "known-schema-divergences.txt");
        var byCase = new Dictionary<string, IReadOnlySet<string>>(StringComparer.Ordinal);
        if (!File.Exists(path)) return new DivergencePolicy(byCase);

        foreach (var rawLine in File.ReadAllLines(path))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var hash = line.IndexOf('#');
            if (hash < 0)
            {
                throw new FormatException(
                    $"Entry '{line}' in known-schema-divergences.txt has no '# reason'. " +
                    "Every accepted divergence has to say why it is acceptable.");
            }

            var declaration = line[..hash].Trim();
            var parts = declaration.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 2)
            {
                throw new FormatException(
                    $"Entry '{declaration}' in known-schema-divergences.txt is malformed: " +
                    "expected '<case-id>  <row-key>  # reason'.");
            }

            var caseId = parts[0];
            var rowKey = parts[1].ToLowerInvariant();

            if (!byCase.TryGetValue(caseId, out var keys))
            {
                keys = new HashSet<string>(StringComparer.Ordinal);
                byCase[caseId] = keys;
            }
            ((HashSet<string>)keys).Add(rowKey);
        }

        return new DivergencePolicy(byCase);
    }
}
