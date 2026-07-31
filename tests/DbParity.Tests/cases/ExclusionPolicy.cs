namespace DbParity.Tests.Cases;

/// <summary>
/// The set of columns excluded from value comparison, read from
/// policy/excluded-columns.txt.
///
/// Keeping this in a file rather than in code is the point: it is short, it is
/// reviewable in a diff, and every entry has to carry its reason.
/// </summary>
public sealed class ExclusionPolicy
{
    private readonly HashSet<string> _qualified;

    private ExclusionPolicy(HashSet<string> qualified) => _qualified = qualified;

    public static ExclusionPolicy Instance { get; } = Load();

    /// <summary>Every excluded column, as <c>schema.table.column</c>.</summary>
    public IReadOnlyCollection<string> QualifiedColumns => _qualified;

    /// <summary>
    /// The excluded column names for one table, unqualified, ready to drop from a
    /// result set. A case declares its table with the <c>@table</c> directive.
    /// </summary>
    public IReadOnlySet<string> ForTable(string qualifiedTable)
    {
        var prefix = qualifiedTable.ToLowerInvariant() + ".";
        return _qualified
            .Where(c => c.StartsWith(prefix, StringComparison.Ordinal))
            .Select(c => c[prefix.Length..])
            .ToHashSet(StringComparer.Ordinal);
    }

    private static ExclusionPolicy Load()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "policy", "excluded-columns.txt");
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"The exclusion policy is missing at '{path}'. It is required: without it, " +
                "columns that cannot match would fail every comparison and hide real defects.",
                path);
        }

        var columns = new HashSet<string>(StringComparer.Ordinal);
        foreach (var rawLine in File.ReadAllLines(path))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            // Strip the trailing "# reason", which is mandatory prose but not data.
            var hash = line.IndexOf('#');
            if (hash >= 0) line = line[..hash].Trim();
            if (line.Length == 0) continue;

            if (line.Count(c => c == '.') != 2)
            {
                throw new FormatException(
                    $"Bad entry '{line}' in excluded-columns.txt: expected schema.table.column.");
            }

            columns.Add(line.ToLowerInvariant());
        }

        return new ExclusionPolicy(columns);
    }
}
