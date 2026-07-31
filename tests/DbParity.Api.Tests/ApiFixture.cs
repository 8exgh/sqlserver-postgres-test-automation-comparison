using System.Net.Http.Json;
using CdnTax.Api.Configuration;
using DbParity.Core.Targets;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Xunit;

// Each test drives a real HTTP pipeline against one of the two containers, and the
// write tests create and delete rows under a shared code prefix. Running them in
// parallel would let one test's cleanup delete another's fixture row.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace DbParity.Api.Tests;

/// <summary>
/// Hosts CdnTax.Api twice in-process -- once bound to SQL Server, once to
/// PostgreSQL -- and hands out an <see cref="HttpClient"/> for each.
///
/// This is the same comparison the rest of the repository makes, moved up one
/// more layer. The C++ CLI tests drive a compiled binary; these drive the whole
/// ASP.NET Core pipeline: routing, model binding, EF Core translation, the
/// database itself, error classification and JSON serialization. Only Kestrel is
/// absent, which is the one part that cannot differ between the two engines.
/// </summary>
public sealed class ApiFixture : IDisposable
{
    private readonly Dictionary<DatabaseProvider, WebApplicationFactory<Program>> _factories = new();
    private readonly Dictionary<DatabaseProvider, HttpClient> _clients = new();

    public ApiFixture()
    {
        AssertFixtureDataAgrees();

        foreach (var provider in Providers)
        {
            var factory = new ProviderFactory(provider);
            _factories[provider] = factory;
            _clients[provider] = factory.CreateClient();
        }

        RemoveLeftoverTestClients();
    }

    /// <summary>Both providers, as <c>Database:Provider</c> spells them.</summary>
    public static IReadOnlyList<DatabaseProvider> Providers { get; } =
        [DatabaseProvider.SqlServer, DatabaseProvider.Postgres];

    /// <summary>
    /// Every client code the write tests create starts with this. Anything carrying
    /// it is disposable, which is what makes cleanup safe to run unconditionally.
    /// </summary>
    public const string TestCodePrefix = "APITEST-";

    public HttpClient Client(DatabaseProvider provider) => _clients[provider];

    /// <summary>
    /// Deletes anything left behind by a run that failed before its own cleanup.
    /// Runs once at session start rather than per test, so a debugging session can
    /// still inspect what a failing test created.
    /// </summary>
    public void RemoveLeftoverTestClients()
    {
        foreach (var provider in Providers)
        {
            var http = _clients[provider];
            var leftovers = http
                .GetFromJsonAsync<List<ClientJson>>($"/api/clients?search={TestCodePrefix}&take=200")
                .GetAwaiter().GetResult() ?? [];

            foreach (var leftover in leftovers.Where(c => c.ClientCode.StartsWith(TestCodePrefix, StringComparison.Ordinal)))
            {
                http.DeleteAsync($"/api/clients/{leftover.ClientId}").GetAwaiter().GetResult();
            }
        }
    }

    /// <summary>
    /// Confirms both databases are reachable and hold the same clients before any
    /// test runs.
    ///
    /// Without it, the cross-engine tests would fail whenever the fixtures had
    /// drifted while saying nothing about the API. This turns that into one precise
    /// message naming the script that fixes it -- the same guard CliFixture applies.
    /// </summary>
    private static void AssertFixtureDataAgrees()
    {
        const string countSql = "SELECT COUNT(*) FROM client.Client";

        using var sqlServer = Connect(() => new SqlServerTarget(), "SQL Server", "scripts/apply-sqlserver.sh");
        using var postgres = Connect(() => new PostgresTarget(), "PostgreSQL", "scripts/apply-postgres.sh");

        var onSqlServer = Convert.ToInt64(sqlServer.Scalar(countSql));
        var onPostgres = Convert.ToInt64(postgres.Scalar(countSql));

        if (onSqlServer != onPostgres)
        {
            throw new InvalidOperationException(
                $"The two databases hold different data: SQL Server has {onSqlServer} clients, " +
                $"PostgreSQL has {onPostgres}.\n" +
                "These tests compare the API's responses from each, so they would fail for a " +
                "reason that has nothing to do with the API.\n" +
                "Sync them with: scripts/replicate-to-postgres.sh");
        }

        if (onSqlServer == 0)
        {
            throw new InvalidOperationException(
                "Both databases are reachable but hold no clients, so every list assertion " +
                "would be vacuously true.\n" +
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
                $"Could not connect to {engine}. Start the containers with `docker compose up -d` " +
                $"and apply the schema with {script}.\n" + ex.Message, ex);
        }
    }

    public void Dispose()
    {
        foreach (var http in _clients.Values) http.Dispose();
        foreach (var factory in _factories.Values) factory.Dispose();
    }

    /// <summary>
    /// The application under test, with the feature flag forced.
    ///
    /// The flag is injected through configuration rather than by swapping the
    /// DbContext registration, so the code path exercised is exactly the one
    /// Program.cs takes in production -- including its refusal to start on an
    /// unrecognised provider name.
    /// </summary>
    private sealed class ProviderFactory(DatabaseProvider provider) : WebApplicationFactory<Program>
    {
        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseSetting("Database:Provider", provider.ToString());

            builder.ConfigureAppConfiguration((_, configuration) =>
            {
                configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["Database:Provider"] = provider.ToString(),
                });
            });
        }
    }
}

/// <summary>One collection for the assembly, so both hosts are started once.</summary>
[CollectionDefinition(Name)]
public sealed class ApiCollection : ICollectionFixture<ApiFixture>
{
    public const string Name = "cdntax-api";
}
