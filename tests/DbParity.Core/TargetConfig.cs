namespace DbParity.Core;

/// <summary>
/// Connection settings for the two engines under comparison.
///
/// Values come from the repository's <c>.env</c> (the same file
/// <c>scripts/apply-*.sh</c> source), with the ports fixed by
/// <c>docker-compose.yml</c>. Every value can be overridden by a real
/// environment variable, which wins over <c>.env</c> so CI can inject
/// credentials without writing a file.
///
/// Nothing here is hardcoded to a password: if neither the environment nor
/// <c>.env</c> supplies one, the same default the compose file declares is
/// used, and only that.
/// </summary>
public static class TargetConfig
{
    private const string ComposeDefaultPassword = "Str0ng!Passw0rd";

    private static readonly Lazy<string> RepoRootLazy = new(FindRepoRoot);
    private static readonly Lazy<IReadOnlyDictionary<string, string>> DotEnvLazy =
        new(() => LoadDotEnv(Path.Combine(RepoRootLazy.Value, ".env")));

    /// <summary>Absolute path to the repository root (the directory holding <c>db/</c>).</summary>
    public static string RepoRoot => RepoRootLazy.Value;

    public static string SqlServerConnectionString =>
        // Encrypt=False because the container presents a self-signed certificate and
        // this is a local fixture; TrustServerCertificate covers the case where a
        // future SqlClient default re-enables encryption.
        $"Server={Setting("MSSQL_HOST", "localhost")},{Setting("MSSQL_PORT", "11433")};" +
        $"Database={Setting("MSSQL_DATABASE", "CdnTaxPractice")};" +
        $"User Id={Setting("MSSQL_USER", "sa")};" +
        $"Password={Setting("MSSQL_SA_PASSWORD", ComposeDefaultPassword)};" +
        "Encrypt=False;TrustServerCertificate=True;" +
        // Generous: the image is amd64-only and runs emulated on Apple Silicon.
        "Connect Timeout=60;Command Timeout=180;";

    public static string PostgresConnectionString =>
        $"Host={Setting("PGHOST", "localhost")};" +
        $"Port={Setting("PGPORT", "15432")};" +
        $"Database={Setting("PGDATABASE", "cdntaxpractice")};" +
        $"Username={Setting("PGUSER", "postgres")};" +
        $"Password={Setting("PGPASSWORD", ComposeDefaultPassword)};" +
        "Timeout=60;Command Timeout=180;";

    private static string Setting(string key, string fallback)
    {
        var fromEnvironment = Environment.GetEnvironmentVariable(key);
        if (!string.IsNullOrWhiteSpace(fromEnvironment)) return fromEnvironment;
        return DotEnvLazy.Value.TryGetValue(key, out var fromFile) && !string.IsNullOrWhiteSpace(fromFile)
            ? fromFile
            : fallback;
    }

    /// <summary>
    /// Walks up from the assembly location looking for the repository markers. The
    /// test binaries live several directories deep under <c>tests/</c>, and the
    /// working directory differs between `dotnet test` and an IDE runner, so
    /// neither can be relied on.
    /// </summary>
    private static string FindRepoRoot()
    {
        var candidates = new[] { AppContext.BaseDirectory, Directory.GetCurrentDirectory() };

        foreach (var start in candidates)
        {
            for (var dir = new DirectoryInfo(start); dir is not null; dir = dir.Parent)
            {
                if (Directory.Exists(Path.Combine(dir.FullName, "db", "sqlserver")) &&
                    File.Exists(Path.Combine(dir.FullName, "docker-compose.yml")))
                {
                    return dir.FullName;
                }
            }
        }

        throw new InvalidOperationException(
            $"Could not locate the repository root above '{AppContext.BaseDirectory}'. " +
            "Expected an ancestor containing both db/sqlserver/ and docker-compose.yml.");
    }

    /// <summary>
    /// Minimal <c>.env</c> reader: <c>KEY=VALUE</c> per line, <c>#</c> comments and
    /// blank lines ignored, optional surrounding quotes stripped. Deliberately not a
    /// general dotenv implementation — it only has to read the file this repository
    /// ships, and a missing file is not an error.
    /// </summary>
    private static IReadOnlyDictionary<string, string> LoadDotEnv(string path)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        if (!File.Exists(path)) return values;

        foreach (var rawLine in File.ReadAllLines(path))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            var separator = line.IndexOf('=');
            if (separator <= 0) continue;

            var key = line[..separator].Trim();
            var value = line[(separator + 1)..].Trim();

            if (value.Length >= 2 &&
                ((value[0] == '"' && value[^1] == '"') || (value[0] == '\'' && value[^1] == '\'')))
            {
                value = value[1..^1];
            }

            values[key] = value;
        }

        return values;
    }
}
