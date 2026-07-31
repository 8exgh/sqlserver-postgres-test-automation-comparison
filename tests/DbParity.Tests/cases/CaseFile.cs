using System.Text;

namespace DbParity.Tests.Cases;

/// <summary>
/// One comparison case, loaded from a .sql file under cases/.
///
/// Cases live on disk as SQL so that adding one touches no C#. The same text is
/// sent to both engines -- which works because SQL Server's collation is
/// case-insensitive and every PostgreSQL object is lowercase-unquoted -- and the
/// two result sets are compared cell by cell.
///
/// Directives are '-- @name value' comment lines at the top of the file:
///
///   @name         display name in the test runner (defaults to the file path)
///   @category     grouping; becomes an xUnit trait
///   @table        schema.table, so the exclusion policy for that table applies
///   @exclude      extra columns to drop, comma-separated
///   @json         columns holding JSON, compared as JSON rather than as text
///                 (SQL Server stores NVARCHAR, the port stores jsonb, and jsonb
///                 reorders keys and drops whitespace)
///   @sort         'client' to re-sort both sides ordinally before comparing,
///                 for cases whose only natural order is on text
///   @allow-empty  the case may legitimately return no rows
///
/// A case that needs genuinely different SQL per engine supplies
/// '&lt;name&gt;.mssql.sql' and '&lt;name&gt;.pgsql.sql' instead of '&lt;name&gt;.sql'.
/// Very few should need it.
/// </summary>
public sealed class CaseFile
{
    private CaseFile(string id, string sqlServerSql, string postgresSql)
    {
        Id = id;
        SqlServerSql = sqlServerSql;
        PostgresSql = postgresSql;
    }

    /// <summary>Path relative to cases/, without extension -- e.g. "tables/client.client".</summary>
    public string Id { get; }

    public string Name { get; private set; } = "";
    public string Category { get; private set; } = "uncategorized";
    public string? Table { get; private set; }
    public bool AllowEmpty { get; private set; }
    public bool SortClientSide { get; private set; }

    /// <summary>
    /// Columns forming the row key used to match entries in
    /// policy/known-schema-divergences.txt. Empty when the case accepts no
    /// divergences, which is the normal state.
    /// </summary>
    public IReadOnlyList<string> DivergenceKey { get; private set; } = [];
    public IReadOnlySet<string> ExtraExclusions { get; private set; } = new HashSet<string>();
    public IReadOnlySet<string> JsonColumns { get; private set; } = new HashSet<string>();

    public string SqlServerSql { get; }
    public string PostgresSql { get; }

    /// <summary>True when the two engines are sent different SQL.</summary>
    public bool IsDivergent => !string.Equals(SqlServerSql, PostgresSql, StringComparison.Ordinal);

    /// <summary>Every column dropped before comparison: the table policy plus the case's own list.</summary>
    public IReadOnlySet<string> ExcludedColumns()
    {
        var excluded = new HashSet<string>(ExtraExclusions, StringComparer.Ordinal);
        if (Table is not null)
        {
            excluded.UnionWith(ExclusionPolicy.Instance.ForTable(Table));
        }
        return excluded;
    }

    public override string ToString() => Name;

    /// <summary>The directory holding the case files, next to the test assembly.</summary>
    public static string CasesRoot => Path.Combine(AppContext.BaseDirectory, "cases");

    /// <summary>
    /// Finds every case under cases/. Engine-specific overrides are folded into the
    /// base case they belong to, so one case is always one test.
    /// </summary>
    public static IReadOnlyList<CaseFile> Discover()
    {
        if (!Directory.Exists(CasesRoot))
        {
            throw new DirectoryNotFoundException(
                $"No case directory at '{CasesRoot}'. Cases are copied to the output " +
                "directory by DbParity.Tests.csproj; try a clean rebuild.");
        }

        var files = Directory.GetFiles(CasesRoot, "*.sql", SearchOption.AllDirectories);
        var byId = new Dictionary<string, (string? Shared, string? Mssql, string? Pgsql)>(StringComparer.Ordinal);

        foreach (var file in files)
        {
            var relative = Path.GetRelativePath(CasesRoot, file).Replace(Path.DirectorySeparatorChar, '/');
            var withoutSql = relative[..^4];

            string id;
            var slot = 0;
            if (withoutSql.EndsWith(".mssql", StringComparison.Ordinal))
            {
                id = withoutSql[..^6];
                slot = 1;
            }
            else if (withoutSql.EndsWith(".pgsql", StringComparison.Ordinal))
            {
                id = withoutSql[..^6];
                slot = 2;
            }
            else
            {
                id = withoutSql;
            }

            byId.TryGetValue(id, out var entry);
            entry = slot switch
            {
                1 => (entry.Shared, file, entry.Pgsql),
                2 => (entry.Shared, entry.Mssql, file),
                _ => (file, entry.Mssql, entry.Pgsql)
            };
            byId[id] = entry;
        }

        var cases = new List<CaseFile>(byId.Count);
        foreach (var (id, entry) in byId.OrderBy(kv => kv.Key, StringComparer.Ordinal))
        {
            cases.Add(Load(id, entry.Shared, entry.Mssql, entry.Pgsql));
        }

        return cases;
    }

    private static CaseFile Load(string id, string? shared, string? mssqlOverride, string? pgsqlOverride)
    {
        // Directives are read from whichever file the case actually has, preferring
        // the shared one so an override does not have to repeat them.
        var directiveSource = shared ?? mssqlOverride ?? pgsqlOverride
            ?? throw new InvalidOperationException($"Case '{id}' has no file.");

        var sharedSql = shared is null ? null : ReadBody(shared);
        var mssqlSql = mssqlOverride is null ? sharedSql : ReadBody(mssqlOverride);
        var pgsqlSql = pgsqlOverride is null ? sharedSql : ReadBody(pgsqlOverride);

        if (mssqlSql is null || pgsqlSql is null)
        {
            throw new InvalidOperationException(
                $"Case '{id}' is incomplete: an engine override needs either a matching " +
                "override for the other engine or a shared '.sql' file.");
        }

        var caseFile = new CaseFile(id, mssqlSql, pgsqlSql);
        caseFile.ApplyDirectives(File.ReadAllLines(directiveSource));
        if (string.IsNullOrWhiteSpace(caseFile.Name)) caseFile.Name = id;
        return caseFile;
    }

    private static string ReadBody(string path)
    {
        var body = new StringBuilder();
        foreach (var line in File.ReadAllLines(path))
        {
            // Directive lines are metadata; everything else, including ordinary
            // comments, is part of the statement.
            if (IsDirective(line, out _, out _)) continue;
            body.AppendLine(line);
        }

        var sql = body.ToString().Trim();
        if (sql.Length == 0)
        {
            throw new InvalidOperationException($"Case file '{path}' contains no SQL.");
        }

        return sql;
    }

    private void ApplyDirectives(IEnumerable<string> lines)
    {
        foreach (var line in lines)
        {
            if (!IsDirective(line, out var key, out var value)) continue;

            switch (key)
            {
                case "name": Name = value; break;
                case "category": Category = value; break;
                case "table": Table = value.ToLowerInvariant(); break;
                case "allow-empty": AllowEmpty = true; break;
                case "sort":
                    SortClientSide = string.Equals(value, "client", StringComparison.OrdinalIgnoreCase);
                    break;
                case "exclude": ExtraExclusions = SplitColumns(value); break;
                case "json": JsonColumns = SplitColumns(value); break;
                case "divergence-key":
                    DivergenceKey = value
                        .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                        .Select(c => c.ToLowerInvariant())
                        .ToArray();
                    break;
                default:
                    throw new FormatException(
                        $"Unknown directive '@{key}' in case '{Id}'. Known directives: " +
                        "name, category, table, exclude, json, sort, allow-empty, divergence-key.");
            }
        }
    }

    private static HashSet<string> SplitColumns(string value) =>
        value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
             .Select(c => c.ToLowerInvariant())
             .ToHashSet(StringComparer.Ordinal);

    private static bool IsDirective(string line, out string key, out string value)
    {
        key = "";
        value = "";

        var trimmed = line.TrimStart();
        if (!trimmed.StartsWith("--", StringComparison.Ordinal)) return false;

        var afterComment = trimmed[2..].TrimStart();
        if (!afterComment.StartsWith('@')) return false;

        var content = afterComment[1..].Trim();
        var space = content.IndexOfAny([' ', '\t']);
        if (space < 0)
        {
            key = content.ToLowerInvariant();
            return key.Length > 0;
        }

        key = content[..space].ToLowerInvariant();
        value = content[space..].Trim();
        return true;
    }
}
