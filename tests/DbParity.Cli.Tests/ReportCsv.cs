using System.Globalization;

namespace DbParity.Cli.Tests;

/// <summary>One assessment row from the register.</summary>
public sealed record ReportRow(
    string ClientCode,
    string DisplayName,
    string Province,
    decimal TaxableIncome,
    decimal FederalTax,
    decimal ProvincialTax,
    decimal Credits,
    decimal BalanceOwing,
    string FilingStatus);

/// <summary>The trailing TOTAL line.</summary>
public sealed record ReportTotal(
    int Count,
    decimal TaxableIncome,
    decimal FederalTax,
    decimal ProvincialTax,
    decimal Credits,
    decimal BalanceOwing);

/// <summary>
/// The tool's <c>--format csv</c> output, parsed.
///
/// Parsing rather than string-matching means a test can assert on the numbers
/// themselves - that the total really is the sum of the rows, that money has two
/// decimal places - instead of on formatting that happens to look right.
/// </summary>
public sealed class ReportCsv
{
    public const string ExpectedHeader =
        "client_code,display_name,province,taxable_income,federal_tax," +
        "provincial_tax,credits,balance_owing,filing_status";

    private ReportCsv(string header, IReadOnlyList<ReportRow> rows, ReportTotal total, string raw)
    {
        Header = header;
        Rows = rows;
        Total = total;
        Raw = raw;
    }

    public string Header { get; }
    public IReadOnlyList<ReportRow> Rows { get; }
    public ReportTotal Total { get; }

    /// <summary>The unmodified text, which is what the cross-engine diff compares.</summary>
    public string Raw { get; }

    public static ReportCsv Parse(string text)
    {
        var lines = text.Replace("\r\n", "\n").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        if (lines.Length < 2)
        {
            throw new FormatException(
                $"expected at least a header and a TOTAL line, got {lines.Length} line(s):\n{text}");
        }

        var header = lines[0];
        var rows = new List<ReportRow>();
        ReportTotal? total = null;

        foreach (var line in lines.Skip(1))
        {
            var fields = SplitCsvLine(line);
            if (fields.Count != 9)
            {
                throw new FormatException($"expected 9 fields, got {fields.Count} in: {line}");
            }

            if (fields[0] == "TOTAL")
            {
                total = new ReportTotal(
                    int.Parse(fields[1], CultureInfo.InvariantCulture),
                    Money(fields[3]), Money(fields[4]), Money(fields[5]),
                    Money(fields[6]), Money(fields[7]));
                continue;
            }

            rows.Add(new ReportRow(
                fields[0], fields[1], fields[2],
                Money(fields[3]), Money(fields[4]), Money(fields[5]),
                Money(fields[6]), Money(fields[7]), fields[8]));
        }

        if (total is null) throw new FormatException($"no TOTAL line in:\n{text}");

        return new ReportCsv(header, rows, total, text);
    }

    private static decimal Money(string field) =>
        decimal.Parse(field, NumberStyles.Number, CultureInfo.InvariantCulture);

    /// <summary>
    /// RFC 4180 field splitting. Not optional here: several client names contain a
    /// comma ("Chen, Amelia"), so a naive Split(',') would shift every column
    /// after the name and the tests would be asserting on the wrong values.
    /// </summary>
    public static List<string> SplitCsvLine(string line)
    {
        var fields = new List<string>();
        var current = new System.Text.StringBuilder();
        var inQuotes = false;

        for (var i = 0; i < line.Length; i++)
        {
            var ch = line[i];

            if (inQuotes)
            {
                if (ch == '"')
                {
                    // A doubled quote inside a quoted field is one literal quote.
                    if (i + 1 < line.Length && line[i + 1] == '"') { current.Append('"'); i++; }
                    else inQuotes = false;
                }
                else current.Append(ch);
            }
            else if (ch == '"') inQuotes = true;
            else if (ch == ',') { fields.Add(current.ToString()); current.Clear(); }
            else current.Append(ch);
        }

        fields.Add(current.ToString());
        return fields;
    }
}
