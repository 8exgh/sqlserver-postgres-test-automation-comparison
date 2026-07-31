using Xunit;

namespace DbParity.Cli.Tests;

/// <summary>
/// The feature flag itself: every test body here runs twice, once per engine,
/// so the legacy SQL Server path and the migrated PostgreSQL path are held to
/// the same standard by the same assertions.
///
/// A [Theory] rather than two [Fact]s on purpose - if the two paths were tested
/// by separate code, the tests could drift apart and stop being a comparison.
/// </summary>
[Collection(CliCollection.Name)]
public sealed class EngineFlagTests
{
    private readonly CliFixture _fixture;

    public EngineFlagTests(CliFixture fixture) => _fixture = fixture;

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Engine_flag_selects_a_working_backend(string engine)
    {
        var result = _fixture.Cli.Run("--engine", engine, "--year", "2024");

        Assert.True(result.Succeeded, result.Detail);
        Assert.Empty(result.StdErr);
        Assert.Contains("T1 ASSESSMENT REGISTER", result.StdOut);
    }

    [Theory]
    [InlineData("postgres", "PostgreSQL")]
    [InlineData("sqlserver", "SQL Server")]
    public void Text_header_names_the_engine_it_read_from(string engine, string expectedProduct)
    {
        var result = _fixture.Cli.Run("--engine", engine, "--year", "2024");

        Assert.True(result.Succeeded, result.Detail);

        var sourceLine = result.StdOut
            .Split('\n')
            .FirstOrDefault(line => line.StartsWith("Source:", StringComparison.Ordinal));

        Assert.NotNull(sourceLine);
        Assert.Contains(expectedProduct, sourceLine);
    }

    [Fact]
    public void Legacy_flag_is_a_synonym_for_the_sqlserver_engine()
    {
        var viaAlias = _fixture.Cli.Run("--legacy", "--year", "2024", "--format", "csv");
        var viaEngine = _fixture.Cli.Run("--engine", "sqlserver", "--year", "2024", "--format", "csv");

        Assert.True(viaAlias.Succeeded, viaAlias.Detail);
        Assert.True(viaEngine.Succeeded, viaEngine.Detail);
        Assert.Equal(viaEngine.StdOut, viaAlias.StdOut);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Engine_aliases_resolve_to_the_same_backend(string engine)
    {
        // The tool accepts a couple of spellings per engine; they must not be
        // silently different backends.
        var alias = engine == "postgres" ? "pg" : "mssql";

        var canonical = _fixture.Cli.Run("--engine", engine, "--year", "2024", "--format", "csv");
        var aliased = _fixture.Cli.Run("--engine", alias, "--year", "2024", "--format", "csv");

        Assert.True(canonical.Succeeded, canonical.Detail);
        Assert.True(aliased.Succeeded, aliased.Detail);
        Assert.Equal(canonical.StdOut, aliased.StdOut);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Csv_output_carries_no_engine_identity(string engine)
    {
        // The CSV is what the cross-engine diff compares, so naming the source in
        // it would make every comparison fail. The engine belongs in the text
        // header only.
        var result = _fixture.Cli.Run("--engine", engine, "--year", "2024", "--format", "csv");

        Assert.True(result.Succeeded, result.Detail);
        Assert.DoesNotContain("PostgreSQL", result.StdOut);
        Assert.DoesNotContain("SQL Server", result.StdOut);
        Assert.DoesNotContain("Source:", result.StdOut);
        Assert.StartsWith(ReportCsv.ExpectedHeader, result.StdOut, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("postgres", "PGPORT")]
    [InlineData("sqlserver", "MSSQL_PORT")]
    public void Unreachable_server_exits_with_the_connection_code(string engine, string portVariable)
    {
        // Exit 3 is documented as "connection failure", distinct from 4 ("query
        // failure"), so a harness can tell a stopped container from a schema
        // change. Overriding the port through the environment exercises the same
        // path the tool uses to read its defaults.
        var environment = new Dictionary<string, string> { [portVariable] = "9" };

        var result = _fixture.Cli.Run(environment, "--engine", engine, "--year", "2024");

        Assert.Equal(3, result.ExitCode);
        Assert.Contains("cannot connect", result.StdErr, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(result.StdOut);
    }

    [Theory]
    [InlineData("postgres")]
    [InlineData("sqlserver")]
    public void Connection_overrides_on_the_command_line_win(string engine)
    {
        // --port beats the environment; pointing it somewhere dead proves the
        // override is actually applied rather than quietly ignored.
        var environment = new Dictionary<string, string>
        {
            ["PGPORT"] = "15432",
            ["MSSQL_PORT"] = "11433",
        };

        var result = _fixture.Cli.Run(environment, "--engine", engine, "--port", "9");

        Assert.Equal(3, result.ExitCode);
    }
}
