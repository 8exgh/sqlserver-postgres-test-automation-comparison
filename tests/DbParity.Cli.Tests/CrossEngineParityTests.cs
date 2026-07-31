using System.Security.Cryptography;
using System.Text;
using Xunit;

namespace DbParity.Cli.Tests;

/// <summary>
/// The point of the whole exercise: the same application, given the same
/// arguments, produces the same report from the legacy SQL Server and from the
/// migrated PostgreSQL.
///
/// This is a stronger statement than "both schemas have 39 tables". It exercises
/// the ported generated columns, the shared query binding on both dialects, both
/// database drivers and the tool's own arithmetic in one assertion - and any
/// difference in any of them shows up as a diff.
/// </summary>
[Collection(CliCollection.Name)]
public sealed class CrossEngineParityTests
{
    private readonly CliFixture _fixture;

    public CrossEngineParityTests(CliFixture fixture) => _fixture = fixture;

    private (CliResult SqlServer, CliResult Postgres) RunBoth(params string[] arguments)
    {
        var postgres = _fixture.Cli.Run(Prepend("postgres", arguments));
        var sqlServer = _fixture.Cli.Run(Prepend("sqlserver", arguments));

        Assert.True(postgres.Succeeded, postgres.Detail);
        Assert.True(sqlServer.Succeeded, sqlServer.Detail);

        return (sqlServer, postgres);
    }

    private static string[] Prepend(string engine, string[] arguments) =>
        new[] { "--engine", engine }.Concat(arguments).ToArray();

    [Theory]
    [InlineData(2023)]
    [InlineData(2024)]
    [InlineData(2025)]
    public void Csv_output_is_byte_identical(int year)
    {
        var (sqlServer, postgres) = RunBoth("--year", year.ToString(), "--format", "csv");

        // Assert on the text, not on a hash: when this fails the reader wants to
        // see which row and which column disagreed, and xUnit's string diff shows
        // exactly that.
        Assert.Equal(postgres.StdOut, sqlServer.StdOut);
    }

    [Theory]
    [InlineData("ON")]
    [InlineData("BC")]
    [InlineData("QC")]
    [InlineData("AB")]
    public void Csv_output_is_byte_identical_per_province(string province)
    {
        var (sqlServer, postgres) =
            RunBoth("--year", "2024", "--province", province, "--format", "csv");

        Assert.Equal(postgres.StdOut, sqlServer.StdOut);
        Assert.NotEmpty(ReportCsv.Parse(postgres.StdOut).Rows);
    }

    [Fact]
    public void Csv_output_has_the_same_checksum()
    {
        // The same claim as above expressed the way a pipeline would record it,
        // and a guard against an assertion that only compares lengths or trims.
        var (sqlServer, postgres) = RunBoth("--year", "2024", "--format", "csv");

        Assert.Equal(Sha256(postgres.StdOut), Sha256(sqlServer.StdOut));
    }

    [Fact]
    public void Parsed_rows_agree_field_by_field()
    {
        // Comparing the parsed model as well as the raw text means a failure can
        // be attributed to a column rather than to a character offset.
        var (sqlServer, postgres) = RunBoth("--year", "2024", "--format", "csv");

        var pg = ReportCsv.Parse(postgres.StdOut);
        var ss = ReportCsv.Parse(sqlServer.StdOut);

        Assert.Equal(pg.Rows.Count, ss.Rows.Count);

        foreach (var (expected, actual) in pg.Rows.Zip(ss.Rows))
        {
            Assert.Equal(expected.ClientCode, actual.ClientCode);
            Assert.Equal(expected.DisplayName, actual.DisplayName);
            Assert.Equal(expected.Province, actual.Province);
            Assert.Equal(expected.TaxableIncome, actual.TaxableIncome);
            Assert.Equal(expected.FederalTax, actual.FederalTax);
            Assert.Equal(expected.ProvincialTax, actual.ProvincialTax);
            Assert.Equal(expected.Credits, actual.Credits);
            Assert.Equal(expected.BalanceOwing, actual.BalanceOwing);
            Assert.Equal(expected.FilingStatus, actual.FilingStatus);
        }

        Assert.Equal(pg.Total, ss.Total);
    }

    [Fact]
    public void Text_reports_differ_only_in_the_source_line()
    {
        // The text format is allowed to name its engine - and must, or the reader
        // cannot tell where the numbers came from. Everything else has to match.
        var (sqlServer, postgres) = RunBoth("--year", "2024");

        var pgLines = WithoutSourceLine(postgres.StdOut);
        var ssLines = WithoutSourceLine(sqlServer.StdOut);

        Assert.Equal(pgLines, ssLines);

        Assert.Contains("Source: PostgreSQL", postgres.StdOut);
        Assert.Contains("Source: SQL Server", sqlServer.StdOut);
    }

    [Fact]
    public void Empty_registers_agree_too()
    {
        // The degenerate case is worth pinning: an empty report still has a header
        // and a zeroed total, and the two engines have to agree on that shape.
        var (sqlServer, postgres) = RunBoth("--year", "1999", "--format", "csv");

        Assert.Equal(postgres.StdOut, sqlServer.StdOut);
        Assert.Empty(ReportCsv.Parse(postgres.StdOut).Rows);
    }

    private static string WithoutSourceLine(string report) =>
        string.Join('\n', report
            .Split('\n')
            .Where(line => !line.StartsWith("Source:", StringComparison.Ordinal)));

    private static string Sha256(string text) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
}
