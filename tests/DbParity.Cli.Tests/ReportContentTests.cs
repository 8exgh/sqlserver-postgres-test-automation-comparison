using Xunit;

namespace DbParity.Cli.Tests;

/// <summary>
/// What the register actually says, asserted against both engines.
///
/// The expected figures are pinned to the shipped fixture
/// (db/sqlserver/021_seed_sample_data.sql). They are not copied from the tool's
/// own output: they were taken from the databases directly, so a change in the
/// tool's arithmetic cannot quietly redefine what "correct" means.
/// </summary>
[Collection(CliCollection.Name)]
public sealed class ReportContentTests
{
    private readonly CliFixture _fixture;

    public ReportContentTests(CliFixture fixture) => _fixture = fixture;

    private ReportCsv Register(string engine, params string[] extra)
    {
        var arguments = new List<string> { "--engine", engine, "--format", "csv" };
        arguments.AddRange(extra);

        var result = _fixture.Cli.Run(arguments.ToArray());
        Assert.True(result.Succeeded, result.Detail);
        return ReportCsv.Parse(result.StdOut);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Csv_header_is_the_documented_contract(string engine)
    {
        var report = Register(engine, "--year", "2024");
        Assert.Equal(ReportCsv.ExpectedHeader, report.Header);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Year_2024_matches_the_shipped_fixture(string engine)
    {
        var report = Register(engine, "--year", "2024");

        Assert.Equal(16, report.Rows.Count);
        Assert.Equal(16, report.Total.Count);
        Assert.Equal(1_399_350.00m, report.Total.TaxableIncome);
        Assert.Equal(246_862.85m, report.Total.FederalTax);
        Assert.Equal(129_758.44m, report.Total.ProvincialTax);
        Assert.Equal(55_370.63m, report.Total.Credits);
        Assert.Equal(-20_986.34m, report.Total.BalanceOwing);
    }

    [Theory]
    [InlineData("postgres", 2023, 13)]
    [InlineData("postgres", 2024, 16)]
    [InlineData("postgres", 2025, 13)]
    [InlineData("sqlserver", 2023, 13)]
    [InlineData("sqlserver", 2024, 16)]
    [InlineData("sqlserver", 2025, 13)]
    public void Year_filter_selects_only_that_year(string engine, int year, int expectedRows)
    {
        var report = Register(engine, "--year", year.ToString());

        Assert.Equal(expectedRows, report.Rows.Count);
        Assert.Equal(expectedRows, report.Total.Count);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Province_filter_narrows_the_register(string engine)
    {
        var all = Register(engine, "--year", "2024");
        var ontario = Register(engine, "--year", "2024", "--province", "ON");

        Assert.Equal(6, ontario.Rows.Count);
        Assert.Equal(591_880.00m, ontario.Total.TaxableIncome);
        Assert.All(ontario.Rows, row => Assert.Equal("ON", row.Province));
        Assert.True(ontario.Rows.Count < all.Rows.Count,
            "the filtered register should be a strict subset");
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Totals_are_the_sum_of_the_rows(string engine)
    {
        // Internal consistency, independent of the pinned figures above: if the
        // tool's integer-cent accumulation ever drifted from the rows it printed,
        // this is what would catch it.
        var report = Register(engine, "--year", "2024");

        Assert.Equal(report.Rows.Count, report.Total.Count);
        Assert.Equal(report.Rows.Sum(r => r.TaxableIncome), report.Total.TaxableIncome);
        Assert.Equal(report.Rows.Sum(r => r.FederalTax), report.Total.FederalTax);
        Assert.Equal(report.Rows.Sum(r => r.ProvincialTax), report.Total.ProvincialTax);
        Assert.Equal(report.Rows.Sum(r => r.Credits), report.Total.Credits);
        Assert.Equal(report.Rows.Sum(r => r.BalanceOwing), report.Total.BalanceOwing);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Money_is_always_two_decimal_places(string engine)
    {
        // The tool carries money as integer cents precisely so the two engines
        // format identically; a value printed as "91150" or "91150.0" on one side
        // would break the diff even though the amount is the same.
        var result = _fixture.Cli.Run("--engine", engine, "--year", "2024", "--format", "csv");
        Assert.True(result.Succeeded, result.Detail);

        var lines = result.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries).Skip(1);
        foreach (var line in lines)
        {
            // Fields 3..7 are the money columns on both data rows and the TOTAL.
            // Split per RFC 4180, not on every comma: "Chen, Amelia" would
            // otherwise shift the money columns one place right and this test
            // would be inspecting the province.
            var fields = ReportCsv.SplitCsvLine(line);
            foreach (var index in new[] { 3, 4, 5, 6, 7 })
            {
                var value = fields[index];
                var point = value.IndexOf('.');
                Assert.True(point >= 0 && value.Length - point - 1 == 2,
                    $"expected two decimal places, got '{value}' in: {line}");
            }
        }
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Rows_are_ordered_by_client_code(string engine)
    {
        // The two engines only produce comparable output because the query pins
        // the order; without ORDER BY neither is obliged to return anything in
        // particular.
        var report = Register(engine, "--year", "2024");
        var codes = report.Rows.Select(r => r.ClientCode).ToList();

        Assert.Equal(codes.OrderBy(c => c, StringComparer.Ordinal).ToList(), codes);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Names_containing_a_comma_are_quoted(string engine)
    {
        // "Chen, Amelia" and friends would shift every later column if the writer
        // did not quote them.
        var result = _fixture.Cli.Run("--engine", engine, "--year", "2024", "--format", "csv");
        Assert.True(result.Succeeded, result.Detail);
        Assert.Contains("\"Chen, Amelia\"", result.StdOut);

        var report = ReportCsv.Parse(result.StdOut);
        var chen = Assert.Single(report.Rows, r => r.ClientCode == "IND-0001");
        Assert.Equal("Chen, Amelia", chen.DisplayName);
        Assert.Equal("ON", chen.Province);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void A_year_with_no_returns_is_an_empty_report_not_a_failure(string engine)
    {
        var result = _fixture.Cli.Run("--engine", engine, "--year", "1999", "--format", "csv");

        Assert.True(result.Succeeded, result.Detail);

        var report = ReportCsv.Parse(result.StdOut);
        Assert.Empty(report.Rows);
        Assert.Equal(0, report.Total.Count);
        Assert.Equal(0m, report.Total.TaxableIncome);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Empty_text_report_is_still_well_formed(string engine)
    {
        var result = _fixture.Cli.Run("--engine", engine, "--year", "1999");

        Assert.True(result.Succeeded, result.Detail);
        Assert.Contains("T1 ASSESSMENT REGISTER", result.StdOut);
        Assert.Contains("(no returns matched)", result.StdOut);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Text_report_includes_a_per_province_breakdown(string engine)
    {
        var result = _fixture.Cli.Run("--engine", engine, "--year", "2024");

        Assert.True(result.Succeeded, result.Detail);
        Assert.Contains("BY PROVINCE", result.StdOut);
        Assert.Contains("TOTALS (16)", result.StdOut);
        Assert.Contains("ON (6)", result.StdOut);
    }
}
