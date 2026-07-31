using System.Data.Common;

namespace DbParity.Core.Results;

/// <summary>
/// One materialized result set, with column names folded to lower-invariant and
/// every value already passed through <see cref="Normalizer"/>.
///
/// Names are folded because SQL Server returns them in the mixed case the schema
/// declares (<c>ClientId</c>) while PostgreSQL returns them lowercased
/// (<c>clientid</c>). That difference is an identifier-quoting artefact, not a
/// schema difference, so it is removed here rather than tolerated per-assertion.
/// </summary>
public sealed class ResultSet
{
    public ResultSet(IReadOnlyList<string> columns, IReadOnlyList<IReadOnlyList<object?>> rows)
    {
        Columns = columns;
        Rows = rows;
    }

    public IReadOnlyList<string> Columns { get; }
    public IReadOnlyList<IReadOnlyList<object?>> Rows { get; }

    public static ResultSet Empty { get; } = new(Array.Empty<string>(), Array.Empty<IReadOnlyList<object?>>());

    /// <summary>Reads the reader's current result set to the end.</summary>
    public static ResultSet Read(DbDataReader reader)
    {
        var columns = new string[reader.FieldCount];
        for (var i = 0; i < reader.FieldCount; i++)
        {
            columns[i] = reader.GetName(i).ToLowerInvariant();
        }

        var rows = new List<IReadOnlyList<object?>>();
        while (reader.Read())
        {
            var row = new object?[reader.FieldCount];
            for (var i = 0; i < reader.FieldCount; i++)
            {
                row[i] = Normalizer.Canonicalize(reader.IsDBNull(i) ? null : reader.GetValue(i));
            }
            rows.Add(row);
        }

        return new ResultSet(columns, rows);
    }

    /// <summary>
    /// Drops the named columns. Used to apply the excluded-column policy: columns
    /// that cannot match by construction (wall-clock timestamps, <c>sa</c> vs
    /// <c>postgres</c> provenance, rowversion) are removed from the value
    /// comparison, while SchemaParityTests still asserts they exist and are typed
    /// as the mapping declares.
    /// </summary>
    public ResultSet WithoutColumns(IReadOnlySet<string> excluded)
    {
        if (excluded.Count == 0) return this;

        var keep = Enumerable.Range(0, Columns.Count)
            .Where(i => !excluded.Contains(Columns[i]))
            .ToArray();

        if (keep.Length == Columns.Count) return this;

        return new ResultSet(
            keep.Select(i => Columns[i]).ToArray(),
            Rows.Select(r => (IReadOnlyList<object?>)keep.Select(i => r[i]).ToArray()).ToArray());
    }

    /// <summary>
    /// Rewrites the named columns into canonical JSON. SQL Server stores these as
    /// NVARCHAR text while the port stores jsonb, which reorders object keys and
    /// drops whitespace -- identical as data, different as text.
    /// </summary>
    public ResultSet WithCanonicalJson(IReadOnlySet<string> jsonColumns)
    {
        if (jsonColumns.Count == 0) return this;

        var targets = Enumerable.Range(0, Columns.Count)
            .Where(i => jsonColumns.Contains(Columns[i]))
            .ToArray();

        if (targets.Length == 0) return this;

        var rows = Rows.Select(row =>
        {
            var copy = row.ToArray();
            foreach (var i in targets)
            {
                if (copy[i] is string text) copy[i] = JsonCanonicalizer.Canonicalize(text);
            }
            return (IReadOnlyList<object?>)copy;
        }).ToArray();

        return new ResultSet(Columns, rows);
    }

    /// <summary>
    /// Drops rows whose key is on the accepted-divergence list. The key is built
    /// from <paramref name="keyColumns"/>, joined with '.' and lowercased, which is
    /// the form policy/known-schema-divergences.txt records.
    ///
    /// Applied to both engines, so an allowlisted row is ignored whichever side it
    /// appears on -- an entry that stops matching anything is stale, and
    /// SchemaPolicyTests reports that rather than letting it rot.
    /// </summary>
    public (ResultSet Filtered, int Dropped) WithoutRows(
        IReadOnlyList<string> keyColumns,
        IReadOnlySet<string> excludedKeys)
    {
        if (keyColumns.Count == 0 || excludedKeys.Count == 0) return (this, 0);

        var indices = keyColumns.Select(name =>
        {
            var index = Columns.ToList().IndexOf(name);
            if (index < 0)
            {
                throw new InvalidOperationException(
                    $"@divergence-key names column '{name}', which the case does not select. " +
                    $"Available: {string.Join(", ", Columns)}.");
            }
            return index;
        }).ToArray();

        var kept = new List<IReadOnlyList<object?>>(Rows.Count);
        var dropped = 0;

        foreach (var row in Rows)
        {
            var key = string.Join('.', indices.Select(i => Normalizer.Render(row[i]).Trim('\'')))
                            .ToLowerInvariant();
            if (excludedKeys.Contains(key)) dropped++;
            else kept.Add(row);
        }

        return (new ResultSet(Columns, kept), dropped);
    }

    /// <summary>
    /// Re-sorts rows by an ordinal rendering of the whole row. For cases whose
    /// ordering cannot be pinned by a numeric key -- because the only sensible sort
    /// is on text, which SQL Server's CI_AS collation and PostgreSQL order
    /// differently.
    /// </summary>
    public ResultSet SortedOrdinally() =>
        new(Columns, Rows.OrderBy(Normalizer.RowSortKey, StringComparer.Ordinal).ToArray());
}
