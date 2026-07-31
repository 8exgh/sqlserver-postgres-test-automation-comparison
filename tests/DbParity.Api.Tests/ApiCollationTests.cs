using System.Net.Http.Json;
using CdnTax.Api.Configuration;
using Xunit;

namespace DbParity.Api.Tests;

/// <summary>
/// Where the API does <em>not</em> behave the same on both engines, asserted
/// rather than left to be discovered.
///
/// SQL Server's collation here is SQL_Latin1_General_CP1_CI_AS, so LIKE is case
/// insensitive. PostgreSQL's LIKE is case sensitive. The <c>search</c> parameter
/// on GET /api/clients passes the caller's text straight into
/// <c>EF.Functions.Like</c>, so a search that works today against SQL Server
/// silently returns nothing after the migration. No error, no warning -- an empty
/// list, which looks exactly like "no matches".
///
/// This is the single most likely way this migration breaks something in
/// production, and unlike the defects the parity tests find, both engines are
/// behaving correctly. Only a test that names the difference will surface it.
///
/// If someone later fixes it -- ILIKE, citext, a case-insensitive collation, or
/// normalising the term the way <c>province</c> already is -- these tests fail and
/// say so. That is the intent: the fix should be deliberate and visible.
/// </summary>
[Collection(ApiCollection.Name)]
public sealed class ApiCollationTests(ApiFixture fixture)
{
    private HttpClient SqlServer => fixture.Client(DatabaseProvider.SqlServer);
    private HttpClient Postgres => fixture.Client(DatabaseProvider.Postgres);

    [Fact]
    public async Task Search_matches_on_both_engines_when_the_case_is_right()
    {
        // The control. DisplayName for the seeded individuals is "Lastname, Firstname",
        // so "Chen" is present exactly as written.
        var onSqlServer = await Search(SqlServer, "Chen");
        var onPostgres = await Search(Postgres, "Chen");

        Assert.NotEmpty(onSqlServer);
        Assert.Equal(onSqlServer.Select(c => c.ClientId), onPostgres.Select(c => c.ClientId));
    }

    [Fact]
    public async Task Search_is_case_insensitive_on_sql_server_only()
    {
        var onSqlServer = await Search(SqlServer, "chen");
        var onPostgres = await Search(Postgres, "chen");

        Assert.NotEmpty(onSqlServer);
        Assert.Empty(onPostgres);
    }

    [Fact]
    public async Task Searching_a_client_code_is_case_insensitive_on_sql_server_only()
    {
        // Client codes are seeded upper case ("IND-0001"), which is exactly the shape
        // of input a user types in lower case.
        var onSqlServer = await Search(SqlServer, "ind-");
        var onPostgres = await Search(Postgres, "ind-");

        Assert.NotEmpty(onSqlServer);
        Assert.Empty(onPostgres);

        // And the upper-case form agrees, which is what makes the above a collation
        // difference rather than a broken filter.
        Assert.Equal(
            (await Search(SqlServer, "IND-")).Select(c => c.ClientId),
            (await Search(Postgres, "IND-")).Select(c => c.ClientId));
    }

    [Fact]
    public async Task The_province_filter_is_immune_because_the_endpoint_normalises_it()
    {
        // The contrast that makes the point. GetClients upper-cases province and type
        // before querying, so those filters behave identically on both engines. search
        // is passed through untouched, and does not. The fix for search is the same
        // one already applied here.
        foreach (var term in new[] { "on", "ON", "oN" })
        {
            var onSqlServer = await fixture.Client(DatabaseProvider.SqlServer)
                .GetFromJsonAsync<List<ClientJson>>($"/api/clients?province={term}&take=200", ApiJson.Options);
            var onPostgres = await fixture.Client(DatabaseProvider.Postgres)
                .GetFromJsonAsync<List<ClientJson>>($"/api/clients?province={term}&take=200", ApiJson.Options);

            Assert.NotEmpty(onSqlServer!);
            Assert.Equal(onSqlServer!.Select(c => c.ClientId), onPostgres!.Select(c => c.ClientId));
        }
    }

    private static async Task<List<ClientJson>> Search(HttpClient http, string term) =>
        await http.GetFromJsonAsync<List<ClientJson>>(
            $"/api/clients?search={Uri.EscapeDataString(term)}&take=200", ApiJson.Options) ?? [];
}
