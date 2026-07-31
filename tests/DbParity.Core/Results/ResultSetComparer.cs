using System.Text;

namespace DbParity.Core.Results;

/// <summary>
/// Compares one result set from each engine and produces a failure report that
/// names the offending cell, rather than "expected true, got false".
///
/// Checks run in order of usefulness and stop when a later check could only
/// produce noise: a column-set mismatch makes every cell "differ", and a
/// row-count mismatch makes row indices meaningless.
/// </summary>
public static class ResultSetComparer
{
    private const int MaxReportedCells = 10;

    /// <summary>
    /// Returns null when the two sides agree, or a multi-line report when they do not.
    /// <paramref name="left"/> is SQL Server, <paramref name="right"/> is PostgreSQL.
    /// </summary>
    public static string? Compare(ResultSet left, ResultSet right)
    {
        if (!left.Columns.SequenceEqual(right.Columns, StringComparer.Ordinal))
        {
            var onlyLeft = left.Columns.Except(right.Columns, StringComparer.Ordinal).ToArray();
            var onlyRight = right.Columns.Except(left.Columns, StringComparer.Ordinal).ToArray();

            var report = new StringBuilder("column sets differ");
            if (onlyLeft.Length > 0) report.Append($"\n  only in sqlserver: {string.Join(", ", onlyLeft)}");
            if (onlyRight.Length > 0) report.Append($"\n  only in postgres:  {string.Join(", ", onlyRight)}");
            if (onlyLeft.Length == 0 && onlyRight.Length == 0)
            {
                report.Append("\n  same names, different order:")
                      .Append($"\n    sqlserver: {string.Join(", ", left.Columns)}")
                      .Append($"\n    postgres:  {string.Join(", ", right.Columns)}");
            }
            return report.ToString();
        }

        if (left.Rows.Count != right.Rows.Count)
        {
            return $"row counts differ: sqlserver={left.Rows.Count}, postgres={right.Rows.Count}" +
                   FirstRowsOnOneSide(left, right);
        }

        var differences = new List<string>();
        var totalDiffering = 0;

        for (var r = 0; r < left.Rows.Count; r++)
        {
            for (var c = 0; c < left.Columns.Count; c++)
            {
                var a = left.Rows[r][c];
                var b = right.Rows[r][c];
                if (ValuesEqual(a, b)) continue;

                totalDiffering++;
                if (differences.Count < MaxReportedCells)
                {
                    differences.Add(
                        $"  row[{r}].{left.Columns[c]}: " +
                        $"sqlserver={Normalizer.Render(a)} ({Normalizer.TypeName(a)}) | " +
                        $"postgres={Normalizer.Render(b)} ({Normalizer.TypeName(b)})");
                }
            }
        }

        if (totalDiffering == 0) return null;

        var summary = new StringBuilder($"{totalDiffering} cell(s) differ across {left.Rows.Count} row(s):\n");
        summary.AppendJoin('\n', differences);
        if (totalDiffering > differences.Count)
        {
            summary.Append($"\n  ... and {totalDiffering - differences.Count} more");
        }
        return summary.ToString();
    }

    /// <summary>
    /// Canonical values are already reduced to a handful of types, so
    /// <see cref="object.Equals(object?, object?)"/> is the right comparison --
    /// notably for decimal, where it compares numeric value and not scale, so
    /// 1.00 from a numeric(19,2) column equals 1 from an integer expression.
    /// Strings compare ordinally, never by the current culture.
    /// </summary>
    private static bool ValuesEqual(object? a, object? b)
    {
        if (a is null || b is null) return a is null && b is null;
        if (a is string sa && b is string sb) return string.Equals(sa, sb, StringComparison.Ordinal);
        return a.Equals(b);
    }

    /// <summary>
    /// When row counts differ, shows the first row present only on the longer side.
    /// Almost always enough to identify what was missed -- a whole table left
    /// unreplicated, or a WHERE clause the port evaluates differently.
    /// </summary>
    private static string FirstRowsOnOneSide(ResultSet left, ResultSet right)
    {
        var (longer, label) = left.Rows.Count > right.Rows.Count
            ? (left, "sqlserver")
            : (right, "postgres");
        var shorterCount = Math.Min(left.Rows.Count, right.Rows.Count);
        if (longer.Rows.Count == shorterCount) return string.Empty;

        var extra = longer.Rows[shorterCount];
        var rendered = string.Join(", ",
            longer.Columns.Select((name, i) => $"{name}={Normalizer.Render(extra[i])}"));
        return $"\n  first row present only in {label} (index {shorterCount}): {rendered}";
    }
}
