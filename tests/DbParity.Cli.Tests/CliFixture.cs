using System.Diagnostics;
using DbParity.Core;
using DbParity.Core.Targets;
using Xunit;

// Every test here starts a child process that connects to one of the two
// containers. Running them in parallel would put the emulated SQL Server under
// pointless concurrent load and make the timeouts flaky.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace DbParity.Cli.Tests;

/// <summary>
/// Locates (and if necessary builds) the C++ binary once, and checks the two
/// preconditions the suite depends on before any test runs.
///
/// The second check matters more than it looks. The headline test asserts that
/// both engines produce identical output; if their sample data had drifted, that
/// test would fail while saying nothing about the application. Comparing the row
/// counts up front turns that into a precise message naming
/// scripts/replicate-to-postgres.sh instead.
/// </summary>
public sealed class CliFixture
{
    public CliFixture()
    {
        RepoRoot = TargetConfig.RepoRoot;
        ExecutablePath = EnsureBuilt();
        Cli = new CliRunner(ExecutablePath);
        AssertFixtureDataAgrees();
    }

    public string RepoRoot { get; }

    public string ExecutablePath { get; }

    public CliRunner Cli { get; }

    /// <summary>Both engine names, as the tool's --engine flag spells them.</summary>
    public static IReadOnlyList<string> Engines { get; } = new[] { "postgres", "sqlserver" };

    private string EnsureBuilt()
    {
        var binary = Path.Combine(RepoRoot, "app", "build", "t1report");
        if (File.Exists(binary)) return binary;

        var cmake = FindOnPath("cmake");
        if (cmake is null)
        {
            throw new InvalidOperationException(
                $"t1report is not built ({binary}) and cmake is not on PATH.\n" +
                "Run scripts/setup-odbc.sh, then:\n" +
                "  cmake -S app -B app/build && cmake --build app/build");
        }

        RunBuildStep(cmake, "-S", "app", "-B", "app/build", "-DCMAKE_BUILD_TYPE=Release");
        RunBuildStep(cmake, "--build", "app/build");

        if (!File.Exists(binary))
        {
            throw new InvalidOperationException(
                $"cmake reported success but {binary} does not exist.");
        }

        return binary;
    }

    private void RunBuildStep(string cmake, params string[] arguments)
    {
        var info = new ProcessStartInfo(cmake)
        {
            WorkingDirectory = RepoRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);

        using var process = Process.Start(info)
            ?? throw new InvalidOperationException("could not start cmake");

        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"cmake {string.Join(' ', arguments)} failed with exit {process.ExitCode}.\n" +
                "The C++ tool needs libpq and unixODBC; run scripts/setup-odbc.sh first.\n" +
                output + error);
        }
    }

    /// <summary>
    /// Confirms both databases are reachable and hold the same number of returns.
    /// Uses the same connections and .env resolution as the rest of the suite, so
    /// a credential change lands in one place.
    /// </summary>
    private static void AssertFixtureDataAgrees()
    {
        const string countSql = "SELECT COUNT(*) FROM tax.T1Return";

        using SqlServerTarget sqlServer = Connect(
            () => new SqlServerTarget(),
            "SQL Server", "scripts/apply-sqlserver.sh");
        using PostgresTarget postgres = Connect(
            () => new PostgresTarget(),
            "PostgreSQL", "scripts/apply-postgres.sh");

        var onSqlServer = Convert.ToInt64(sqlServer.Scalar(countSql));
        var onPostgres = Convert.ToInt64(postgres.Scalar(countSql));

        if (onSqlServer != onPostgres)
        {
            throw new InvalidOperationException(
                $"The two databases hold different sample data: SQL Server has {onSqlServer} " +
                $"T1 returns, PostgreSQL has {onPostgres}.\n" +
                "The cross-engine tests compare the tool's output from each, so they would " +
                "fail for a reason that has nothing to do with the tool.\n" +
                "Sync them with: scripts/replicate-to-postgres.sh");
        }

        if (onSqlServer == 0)
        {
            throw new InvalidOperationException(
                "Both databases are reachable but hold no T1 returns, so the report would be " +
                "empty and the assertions vacuous.\n" +
                "Load the fixture with: scripts/apply-sqlserver.sh && scripts/replicate-to-postgres.sh");
        }
    }

    private static T Connect<T>(Func<T> create, string engine, string script)
    {
        try
        {
            return create();
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                $"Could not connect to {engine}. Start the containers with " +
                $"`docker compose up -d` and apply the schema with {script}.\n" + ex.Message,
                ex);
        }
    }

    private static string? FindOnPath(string command)
    {
        var path = Environment.GetEnvironmentVariable("PATH");
        if (path is null) return null;

        foreach (var directory in path.Split(Path.PathSeparator))
        {
            if (directory.Length == 0) continue;
            var candidate = Path.Combine(directory, command);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}

/// <summary>
/// One collection for the assembly, so the binary is located or built once and
/// the precondition checks run once.
/// </summary>
[CollectionDefinition(Name)]
public sealed class CliCollection : ICollectionFixture<CliFixture>
{
    public const string Name = "t1report-cli";
}
