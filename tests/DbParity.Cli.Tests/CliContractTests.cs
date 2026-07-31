using Xunit;

namespace DbParity.Cli.Tests;

/// <summary>
/// The command-line contract, which is engine-independent: argument validation
/// and exit codes.
///
/// These deliberately assert on exit codes rather than on message wording. A
/// harness branches on the code, so that is what has to stay stable; the text is
/// for humans and is allowed to improve.
/// </summary>
[Collection(CliCollection.Name)]
public sealed class CliContractTests
{
    private const int ExitOk = 0;
    private const int ExitUsage = 2;

    private readonly CliFixture _fixture;

    public CliContractTests(CliFixture fixture) => _fixture = fixture;

    [Theory]
    [InlineData("--help")]
    [InlineData("-h")]
    public void Help_succeeds_and_documents_both_engines(string flag)
    {
        var result = _fixture.Cli.Run(flag);

        Assert.Equal(ExitOk, result.ExitCode);
        Assert.Contains("--engine", result.StdOut);
        Assert.Contains("postgres", result.StdOut);
        Assert.Contains("sqlserver", result.StdOut);
        Assert.Contains("--legacy", result.StdOut);
    }

    [Fact]
    public void Engine_is_required()
    {
        // Defaulting to one engine would make it far too easy to believe a report
        // came from the other.
        var result = _fixture.Cli.Run();

        Assert.Equal(ExitUsage, result.ExitCode);
        Assert.Contains("--engine", result.StdErr);
        Assert.Empty(result.StdOut);
    }

    [Theory]
    [InlineData("oracle")]
    [InlineData("Postgres")]   // the parser is case-sensitive; a near miss must not silently pass
    [InlineData("")]
    public void Unknown_engine_is_a_usage_error(string engine)
    {
        var result = _fixture.Cli.Run("--engine", engine);

        Assert.Equal(ExitUsage, result.ExitCode);
        Assert.Contains("--engine", result.StdErr);
    }

    [Theory]
    [InlineData("--year")]
    [InlineData("--province")]
    [InlineData("--format")]
    [InlineData("--host")]
    [InlineData("--port")]
    public void An_option_missing_its_value_is_a_usage_error(string option)
    {
        // The option is last, so there is no value to take.
        var result = _fixture.Cli.Run("--engine", "postgres", option);

        Assert.Equal(ExitUsage, result.ExitCode);
        Assert.Contains(option, result.StdErr);
    }

    [Theory]
    [InlineData("abc")]
    [InlineData("2024x")]
    [InlineData("")]
    public void A_non_numeric_year_is_a_usage_error(string year)
    {
        var result = _fixture.Cli.Run("--engine", "postgres", "--year", year);

        Assert.Equal(ExitUsage, result.ExitCode);
        Assert.Contains("--year", result.StdErr);
    }

    [Fact]
    public void An_unknown_format_is_a_usage_error()
    {
        var result = _fixture.Cli.Run("--engine", "postgres", "--format", "xml");

        Assert.Equal(ExitUsage, result.ExitCode);
        Assert.Contains("--format", result.StdErr);
    }

    [Fact]
    public void An_unknown_option_is_a_usage_error()
    {
        var result = _fixture.Cli.Run("--engine", "postgres", "--favourite-colour", "blue");

        Assert.Equal(ExitUsage, result.ExitCode);
        Assert.Contains("--favourite-colour", result.StdErr);
    }

    [Fact]
    public void Usage_errors_print_the_help_text()
    {
        // Being told what is wrong without being told the shape of the command is
        // half an error message.
        var result = _fixture.Cli.Run("--engine", "oracle");

        Assert.Equal(ExitUsage, result.ExitCode);
        Assert.Contains("usage: t1report", result.StdErr);
    }

    [Fact]
    public void Diagnostics_go_to_stderr_so_stdout_stays_pipeable()
    {
        // The CSV is meant to be redirected straight into a diff; anything the
        // tool has to say about a failure must not land in it.
        var result = _fixture.Cli.Run("--engine", "oracle");

        Assert.Empty(result.StdOut);
        Assert.NotEmpty(result.StdErr);
    }
}
