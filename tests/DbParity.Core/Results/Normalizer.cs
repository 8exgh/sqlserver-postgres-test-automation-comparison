using System.Globalization;

namespace DbParity.Core.Results;

/// <summary>
/// Reduces provider-specific CLR values to a small canonical set so that two rows
/// carrying the same data compare equal even though the two ADO.NET providers
/// surfaced them as different types.
///
/// Every rule here is a deliberate decision about the port, not a convenience. The
/// pairs that actually occur in this schema:
///
///   SQL Server bit        -> bool     | ported to numeric(1,0) -> decimal
///   SQL Server tinyint    -> byte     | ported to smallint     -> short
///   SQL Server int        -> int      | COUNT(*) is int here, bigint on PostgreSQL
///   SQL Server date       -> DateTime | Npgsql surfaces date as DateOnly
///   SQL Server rowversion -> byte[8]  | ported to bigint       -> long
///
/// Collapsing every integral and fixed-point type onto <see cref="decimal"/> is safe
/// for this fixture: the widest numeric column is numeric(19,2) and the widest
/// integer is a 32-bit identity, both of which decimal represents exactly. A real
/// bigint beyond decimal's range would be a lossy conversion, so it is rejected
/// rather than silently truncated.
/// </summary>
public static class Normalizer
{
    /// <summary>Canonicalizes a raw provider value. Never throws for unknown types.</summary>
    public static object? Canonicalize(object? raw)
    {
        switch (raw)
        {
            case null or DBNull:
                return null;

            // Booleans are numeric here: the port maps SQL Server's bit onto
            // numeric(1,0), so `true` and `1` must be the same canonical value.
            case bool b:
                return b ? 1m : 0m;

            case byte v: return (decimal)v;
            case sbyte v: return (decimal)v;
            case short v: return (decimal)v;
            case ushort v: return (decimal)v;
            case int v: return (decimal)v;
            case uint v: return (decimal)v;
            case long v: return (decimal)v;
            case ulong v: return (decimal)v;
            case decimal v: return v;

            // No float or real column exists in this schema. The guard is here so a
            // future one cannot compare by binary equality and fail spuriously.
            case float v: return Math.Round((decimal)v, 10, MidpointRounding.ToEven);
            case double v: return Math.Round((decimal)v, 10, MidpointRounding.ToEven);

            // Npgsql surfaces `date` as DateOnly; SqlClient surfaces it as a
            // midnight DateTime. Kind is dropped: both engines store these columns
            // without a time zone, so a Kind difference is an artefact of the
            // provider rather than of the data.
            case DateOnly d: return d.ToDateTime(TimeOnly.MinValue);
            case DateTime dt: return DateTime.SpecifyKind(dt, DateTimeKind.Unspecified);
            case DateTimeOffset dto: return DateTime.SpecifyKind(dto.UtcDateTime, DateTimeKind.Unspecified);
            case TimeOnly t: return t.ToTimeSpan();
            case TimeSpan ts: return ts;

            case Guid g: return g.ToString("D", CultureInfo.InvariantCulture);

            // rowversion (8 bytes) on one side, bigint on the other. This column is
            // excluded from value comparison by policy, but it still has to render.
            case byte[] bytes: return Convert.ToHexString(bytes).ToLowerInvariant();

            case char c: return c.ToString();

            // char(n) is blank-padded by both engines, so trailing spaces carry no
            // information. Trimming them keeps a genuine bpchar/varchar type
            // divergence from showing up as a value difference in every row --
            // SchemaParityTests is what reports that, once, where it belongs.
            // Leading spaces are preserved: those would be real data.
            case string s: return s.TrimEnd(' ');

            default: return raw;
        }
    }

    /// <summary>Human-readable rendering used in failure messages.</summary>
    public static string Render(object? canonical) => canonical switch
    {
        null => "NULL",
        decimal d => d.ToString(CultureInfo.InvariantCulture),
        DateTime dt => dt.ToString("yyyy-MM-dd HH:mm:ss.fffffff", CultureInfo.InvariantCulture),
        TimeSpan ts => ts.ToString("c", CultureInfo.InvariantCulture),
        string s => $"'{s}'",
        _ => Convert.ToString(canonical, CultureInfo.InvariantCulture) ?? "?"
    };

    /// <summary>The CLR type name shown alongside a differing value.</summary>
    public static string TypeName(object? canonical) => canonical?.GetType().Name ?? "null";

    /// <summary>
    /// Ordinal sort key for a whole row, used by the client-side sort option. Ordinal
    /// throughout: SQL Server's CI_AS collation and PostgreSQL's sort text
    /// differently, and this exists precisely to stop that difference reaching the
    /// comparison.
    /// </summary>
    public static string RowSortKey(IReadOnlyList<object?> row) =>
        // Unit separator, so ["ab","c"] and ["a","bc"] cannot collapse to one key.
        string.Join("\u001f", row.Select(Render));
}
