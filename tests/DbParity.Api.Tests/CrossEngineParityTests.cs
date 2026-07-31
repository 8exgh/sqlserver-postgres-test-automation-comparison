using System.Net;
using System.Net.Http.Json;
using CdnTax.Api.Configuration;
using Xunit;
using Xunit.Sdk;

namespace DbParity.Api.Tests;

/// <summary>
/// The headline: the same request, sent to the SQL Server-backed API and the
/// PostgreSQL-backed API, must come back the same.
///
/// Everything else in this project checks that each engine behaves correctly on
/// its own. This checks the thing the migration actually promises -- that a
/// consumer cannot tell which engine is underneath. It is the CLI suite's
/// CrossEngineParityTests moved up to HTTP, and it is the assertion that would
/// catch a defect the per-engine tests both happily agree on.
/// </summary>
[Collection(ApiCollection.Name)]
public sealed class CrossEngineParityTests(ApiFixture fixture)
{
    private HttpClient SqlServer => fixture.Client(DatabaseProvider.SqlServer);
    private HttpClient Postgres => fixture.Client(DatabaseProvider.Postgres);

    /// <summary>Every read endpoint whose response must be byte-identical.</summary>
    public static TheoryData<string> ReadPaths =>
    [
        "/api/clients?take=200",
        "/api/clients?take=5",
        "/api/clients?skip=10&take=10",
        "/api/clients?province=ON&take=200",
        "/api/clients?province=BC&take=200",
        "/api/clients?province=QC&take=200",
        "/api/clients?type=I&take=200",
        "/api/clients?type=C&take=200",
        "/api/clients?active=true&take=200",
        "/api/clients?active=false&take=200",
        "/api/clients?province=ON&type=I&active=true&take=200",
        "/api/clients?search=Chen&take=200",
        "/api/clients?search=Ltd&take=200",
        "/api/clients?search=IND-&take=200",
        "/api/provinces",
        "/api/practitioners",
        "/api/tax-years",
    ];

    [Theory]
    [MemberData(nameof(ReadPaths))]
    public async Task Both_engines_return_identical_json(string path)
    {
        var (sqlServer, postgres) = await BothAsync(path);

        Assert.Equal(sqlServer.Status, postgres.Status);
        AssertSameJson(sqlServer.Body, postgres.Body, path);

        // A path that returns an empty array compares equal while asserting nothing.
        Assert.True(sqlServer.Body.Length > 2,
            $"{path} returned an empty document on both engines, so this case is vacuous.");
    }

    [Fact]
    public async Task Every_client_is_identical_when_fetched_individually()
    {
        // The list endpoint could agree while a single-row read diverged -- different
        // code path, and it is the one a detail page uses.
        var clients = await SqlServer.GetFromJsonAsync<List<ClientJson>>("/api/clients?take=200", ApiJson.Options);
        Assert.NotEmpty(clients!);

        foreach (var client in clients!)
        {
            var path = $"/api/clients/{client.ClientId}";
            var (sqlServer, postgres) = await BothAsync(path);
            Assert.Equal(sqlServer.Status, postgres.Status);
            AssertSameJson(sqlServer.Body, postgres.Body, path);
        }
    }

    [Fact]
    public async Task Every_client_has_identical_engagements()
    {
        var clients = await SqlServer.GetFromJsonAsync<List<ClientJson>>("/api/clients?take=200", ApiJson.Options);
        var withEngagements = 0;

        foreach (var client in clients!)
        {
            var path = $"/api/clients/{client.ClientId}/engagements";
            var (sqlServer, postgres) = await BothAsync(path);
            Assert.Equal(sqlServer.Status, postgres.Status);
            AssertSameJson(sqlServer.Body, postgres.Body, path);

            if (sqlServer.Body.Length > 2) withEngagements++;
        }

        Assert.True(withEngagements > 0,
            "No client returned any engagements, so the join was never actually compared.");
    }

    [Fact]
    public async Task Health_agrees_on_everything_except_which_engine_it_is()
    {
        var sqlServer = await SqlServer.GetFromJsonAsync<HealthJson>("/api/health", ApiJson.Options);
        var postgres = await Postgres.GetFromJsonAsync<HealthJson>("/api/health", ApiJson.Options);

        // The inverse of the tests above: these three MUST differ, or the feature
        // flag did not switch anything and every other comparison here is worthless.
        Assert.NotEqual(sqlServer!.Provider, postgres!.Provider);
        Assert.NotEqual(sqlServer.DataSource, postgres.DataSource);

        Assert.True(sqlServer.CanConnect && postgres.CanConnect);
        Assert.Equal(sqlServer.ClientCount, postgres.ClientCount);
    }

    [Fact]
    public async Task A_client_created_through_each_api_is_equivalent()
    {
        await using var onSqlServer = fixture.Lifecycle(DatabaseProvider.SqlServer);
        await using var onPostgres = fixture.Lifecycle(DatabaseProvider.Postgres);

        var code = ClientLifecycle.NewCode("P1");
        var body = ClientLifecycle.Individual(code);

        var (sqlServerResponse, sqlServerClient) = await onSqlServer.CreateAsync(body);
        var (postgresResponse, postgresClient) = await onPostgres.CreateAsync(body);

        Assert.Equal(HttpStatusCode.Created, sqlServerResponse.StatusCode);
        Assert.Equal(HttpStatusCode.Created, postgresResponse.StatusCode);

        // Three fields cannot match and are excluded rather than fudged:
        //
        //   clientId    two databases allocating independently from their own
        //               identity counters, which a rolled-back or failed test on one
        //               side is enough to desynchronise
        //   createdAt   defaulted by each engine's own clock, milliseconds apart
        //   rowVersion  a native ROWVERSION counter on one side, a sequence driven by
        //               client.tr_client_biu on the other -- unrelated number spaces
        //
        // Everything a consumer would actually assert on must match, including
        // displayName, which each engine computed for itself.
        var expected = ApiJson.CanonicalWithout(
            await sqlServerResponse.Content.ReadAsStringAsync(), "clientId", "createdAt", "rowVersion");
        var actual = ApiJson.CanonicalWithout(
            await postgresResponse.Content.ReadAsStringAsync(), "clientId", "createdAt", "rowVersion");

        Assert.Equal(expected, actual);
        Assert.Equal("Lovelace, Ada", sqlServerClient!.DisplayName);
        Assert.Equal("Lovelace, Ada", postgresClient!.DisplayName);
    }

    [Fact]
    public async Task The_same_invalid_request_is_rejected_identically()
    {
        // Validation runs before either database is touched, so these responses
        // should be identical including the message text.
        var body = new
        {
            clientCode = ClientLifecycle.NewCode("P2"),
            clientType = "I",
            firstName = "X",
            lastName = "Y",
            dateOfBirth = "1990-01-01",
            legalName = "Corporations only",
            provinceCode = "ON",
            onboardedDate = "2024-02-01",
        };

        var sqlServer = await SqlServer.PostAsJsonAsync("/api/clients", body);
        var postgres = await Postgres.PostAsJsonAsync("/api/clients", body);

        Assert.Equal(HttpStatusCode.BadRequest, sqlServer.StatusCode);
        Assert.Equal(postgres.StatusCode, sqlServer.StatusCode);

        // traceId is excluded: ProblemDetails carries the W3C trace context of the
        // individual request, so it is unique per call and would differ between two
        // requests to the same host. Everything else -- title, status, type, and the
        // per-field errors dictionary -- must match exactly.
        var expected = ApiJson.CanonicalWithout(await sqlServer.Content.ReadAsStringAsync(), "traceId");
        var actual = ApiJson.CanonicalWithout(await postgres.Content.ReadAsStringAsync(), "traceId");

        Assert.Equal(expected, actual);
        Assert.Contains("legalName", expected, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task A_constraint_violation_produces_the_same_status_on_both()
    {
        await using var onSqlServer = fixture.Lifecycle(DatabaseProvider.SqlServer);
        await using var onPostgres = fixture.Lifecycle(DatabaseProvider.Postgres);

        var code = ClientLifecycle.NewCode("P3");
        var body = ClientLifecycle.Individual(code);

        await onSqlServer.CreateAsync(body);
        await onPostgres.CreateAsync(body);

        var (sqlServerDuplicate, _) = await onSqlServer.CreateAsync(body);
        var (postgresDuplicate, _) = await onPostgres.CreateAsync(body);

        // The STATUS must match. The body must not be compared: the detail carries
        // the driver's own message, which names UQ_Client_ClientCode on one engine
        // and uq_client_clientcode with different wording on the other. That is
        // DbErrorTranslator doing its job, not a divergence -- and asserting the
        // text would pin the suite to two vendors' error strings.
        Assert.Equal(HttpStatusCode.Conflict, sqlServerDuplicate.StatusCode);
        Assert.Equal(HttpStatusCode.Conflict, postgresDuplicate.StatusCode);
    }

    // ------------------------------------------------------------------

    private async Task<(Response SqlServer, Response Postgres)> BothAsync(string path)
    {
        var sqlServer = await SqlServer.GetAsync(path);
        var postgres = await Postgres.GetAsync(path);

        return (
            new Response(sqlServer.StatusCode, await sqlServer.Content.ReadAsStringAsync()),
            new Response(postgres.StatusCode, await postgres.Content.ReadAsStringAsync()));
    }

    private static void AssertSameJson(string sqlServerBody, string postgresBody, string context)
    {
        var expected = ApiJson.Canonical(sqlServerBody);
        var actual = ApiJson.Canonical(postgresBody);
        if (expected == actual) return;

        throw new XunitException(
            $"{context} returned different JSON.\n{FirstDifference(expected, actual)}");
    }

    /// <summary>
    /// Two 200 KB documents differing in one character is unreadable as a raw diff,
    /// so report the offset and a window around it.
    /// </summary>
    private static string FirstDifference(string expected, string actual)
    {
        var limit = Math.Min(expected.Length, actual.Length);
        var index = 0;
        while (index < limit && expected[index] == actual[index]) index++;

        if (index == limit && expected.Length != actual.Length)
        {
            return $"  identical for {limit} chars, then lengths differ: " +
                   $"sqlserver={expected.Length}, postgres={actual.Length}\n" +
                   $"  sqlserver tail: {Window(expected, limit)}\n" +
                   $"  postgres  tail: {Window(actual, limit)}";
        }

        return $"  first difference at offset {index}\n" +
               $"  sqlserver: {Window(expected, index)}\n" +
               $"  postgres:  {Window(actual, index)}";
    }

    private static string Window(string text, int around)
    {
        var start = Math.Max(0, around - 60);
        var length = Math.Min(160, text.Length - start);
        return length <= 0 ? "<end>" : text.Substring(start, length);
    }

    private sealed record Response(HttpStatusCode Status, string Body);
}
