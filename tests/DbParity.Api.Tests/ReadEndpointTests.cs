using System.Net;
using System.Net.Http.Json;
using CdnTax.Api.Configuration;
using Xunit;

namespace DbParity.Api.Tests;

/// <summary>
/// The read surface, exercised against both engines.
///
/// Every test here is a <see cref="TheoryAttribute"/> over the provider rather
/// than two sets of facts. If the SQL Server path and the PostgreSQL path were
/// asserted by separate code they could drift apart and stop being a comparison at
/// all -- the same reasoning the CLI suite's EngineFlagTests records.
/// </summary>
[Collection(ApiCollection.Name)]
public sealed class ReadEndpointTests(ApiFixture fixture)
{
    public static TheoryData<DatabaseProvider> Providers => Theories.Providers;

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Health_reports_the_provider_it_was_flagged_with(DatabaseProvider provider)
    {
        var health = await fixture.Client(provider).GetFromJsonAsync<HealthJson>("/api/health", ApiJson.Options);

        Assert.NotNull(health);
        Assert.Equal(provider.ToString(), health.Provider);
        Assert.True(health.CanConnect, $"The API could not reach its {provider} database.");
        Assert.True(health.ClientCount > 0, "The fixture is empty, so every other assertion would be vacuous.");
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Client_list_is_ordered_and_paged(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);

        var firstPage = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?take=5", ApiJson.Options);
        var secondPage = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?skip=5&take=5", ApiJson.Options);

        Assert.NotNull(firstPage);
        Assert.NotNull(secondPage);
        Assert.Equal(5, firstPage.Count);

        // Ordered by ClientId, so the pages must not overlap and must ascend.
        Assert.Equal(firstPage.Select(c => c.ClientId).OrderBy(id => id), firstPage.Select(c => c.ClientId));
        Assert.Empty(firstPage.Select(c => c.ClientId).Intersect(secondPage.Select(c => c.ClientId)));
        Assert.True(firstPage[^1].ClientId < secondPage[0].ClientId);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Take_is_clamped_to_the_documented_maximum(DatabaseProvider provider)
    {
        // Math.Clamp(take, 1, 200) in the endpoint. Asserted because an unbounded
        // take is how a list endpoint becomes a denial of service.
        var clients = await fixture.Client(provider)
            .GetFromJsonAsync<List<ClientJson>>("/api/clients?take=100000", ApiJson.Options);

        Assert.NotNull(clients);
        Assert.True(clients.Count <= 200, $"take was not clamped: {clients.Count} rows came back.");
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Province_filter_selects_only_that_province(DatabaseProvider provider)
    {
        var clients = await fixture.Client(provider)
            .GetFromJsonAsync<List<ClientJson>>("/api/clients?province=ON&take=200", ApiJson.Options);

        Assert.NotNull(clients);
        Assert.NotEmpty(clients);
        Assert.All(clients, c => Assert.Equal("ON", c.ProvinceCode));
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Province_filter_is_case_insensitive_at_the_api_boundary(DatabaseProvider provider)
    {
        // The endpoint upper-cases the parameter before querying. That is what makes
        // this behave the same on both engines despite PostgreSQL comparing text
        // case-sensitively -- see ApiCollationTests for where it does not.
        var http = fixture.Client(provider);

        var upper = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?province=ON&take=200", ApiJson.Options);
        var lower = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?province=on&take=200", ApiJson.Options);

        Assert.NotNull(upper);
        Assert.NotNull(lower);
        Assert.NotEmpty(upper);
        Assert.Equal(upper.Select(c => c.ClientId), lower.Select(c => c.ClientId));
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Type_filter_selects_only_that_type(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);

        var corporations = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?type=C&take=200", ApiJson.Options);
        var individuals = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?type=I&take=200", ApiJson.Options);

        Assert.NotNull(corporations);
        Assert.NotNull(individuals);
        Assert.NotEmpty(corporations);
        Assert.NotEmpty(individuals);
        Assert.All(corporations, c => Assert.Equal("C", c.ClientType));
        Assert.All(individuals, c => Assert.Equal("I", c.ClientType));

        // A corporation carries a legal name and no personal fields, per
        // CK_Client_TypeShape. The generated DisplayName follows from that.
        Assert.All(corporations, c => Assert.Null(c.FirstName));
        Assert.All(corporations, c => Assert.Equal(c.LegalName, c.DisplayName));
        Assert.All(individuals, c => Assert.Equal($"{c.LastName}, {c.FirstName}", c.DisplayName));
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Active_filter_partitions_the_set(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);

        var all = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?take=200", ApiJson.Options);
        var active = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?active=true&take=200", ApiJson.Options);
        var inactive = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?active=false&take=200", ApiJson.Options);

        Assert.NotNull(all);
        Assert.NotNull(active);
        Assert.NotNull(inactive);

        // BIT on SQL Server, NUMERIC(1,0) on PostgreSQL, bool in the model. The
        // partition holding is what proves the converter round-trips in the WHERE
        // clause and not only on read.
        Assert.All(active, c => Assert.True(c.IsActive));
        Assert.All(inactive, c => Assert.False(c.IsActive));
        Assert.Equal(all.Count, active.Count + inactive.Count);
        Assert.NotEmpty(active);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Get_by_id_matches_the_row_from_the_list(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);

        var listed = (await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?take=1", ApiJson.Options))!.Single();
        var fetched = await http.GetFromJsonAsync<ClientJson>($"/api/clients/{listed.ClientId}", ApiJson.Options);

        Assert.Equal(listed, fetched);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Unknown_client_is_404(DatabaseProvider provider)
    {
        var response = await fixture.Client(provider).GetAsync("/api/clients/999999");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Non_integer_id_does_not_match_the_route(DatabaseProvider provider)
    {
        // The route constrains {id:int}; "abc" should not reach the handler and be
        // reported as a database error.
        var response = await fixture.Client(provider).GetAsync("/api/clients/abc");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Engagements_resolve_their_practitioner(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);

        // Pick a client that actually has engagements, so the assertion is not vacuous.
        var clients = await http.GetFromJsonAsync<List<ClientJson>>("/api/clients?take=200", ApiJson.Options);
        List<EngagementJson>? engagements = null;
        int clientId = 0;

        foreach (var client in clients!)
        {
            var candidate = await http.GetFromJsonAsync<List<EngagementJson>>(
                $"/api/clients/{client.ClientId}/engagements", ApiJson.Options);
            if (candidate is { Count: > 0 })
            {
                engagements = candidate;
                clientId = client.ClientId;
                break;
            }
        }

        Assert.True(engagements is not null, "No seeded client has any engagements; the fixture is incomplete.");
        Assert.All(engagements!, e => Assert.Equal(clientId, e.ClientId));

        // The Include(e => e.Practitioner) is what this is really checking: a join
        // EF translates differently per provider.
        Assert.All(engagements!, e => Assert.True(
            e.PractitionerId is null || !string.IsNullOrWhiteSpace(e.PractitionerName),
            $"Engagement {e.EngagementId} has practitioner {e.PractitionerId} but no name."));

        // Ordered by TaxYear then ServiceType.
        Assert.Equal(
            engagements!.OrderBy(e => e.TaxYear).ThenBy(e => e.ServiceType, StringComparer.Ordinal).Select(e => e.EngagementId),
            engagements!.Select(e => e.EngagementId));
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Engagements_for_an_unknown_client_are_404(DatabaseProvider provider)
    {
        var response = await fixture.Client(provider).GetAsync("/api/clients/999999/engagements");
        Assert.Equal(HttpStatusCode.NotFound, response.StatusCode);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Lookups_return_the_seeded_reference_data(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);

        var provinces = await http.GetFromJsonAsync<List<ProvinceJson>>("/api/provinces", ApiJson.Options);
        var practitioners = await http.GetFromJsonAsync<List<PractitionerJson>>("/api/practitioners", ApiJson.Options);
        var taxYears = await http.GetFromJsonAsync<List<TaxYearJson>>("/api/tax-years", ApiJson.Options);

        // Counts pinned to db/README.md's seed table: 13 provinces, 5 practitioners,
        // 3 tax years. ref.* is seeded independently on each engine, so these being
        // equal on both is a real check of the ported seed rather than of replication.
        Assert.Equal(13, provinces!.Count);
        Assert.Equal(5, practitioners!.Count);
        Assert.Equal(3, taxYears!.Count);

        // CHAR(2) is space-padded by SQL Server; the endpoint trims it.
        Assert.All(provinces, p => Assert.Equal(2, p.ProvinceCode.Length));
        Assert.Contains(provinces, p => p.ProvinceCode == "ON");

        Assert.Equal(provinces.OrderBy(p => p.SortOrder).Select(p => p.ProvinceCode), provinces.Select(p => p.ProvinceCode));
        Assert.Equal(taxYears.OrderByDescending(t => t.TaxYear).Select(t => t.TaxYear), taxYears.Select(t => t.TaxYear));

        // 021_seed_sample_data.sql locks 2023 at the end of the seed. The replicator
        // carries that across; if it stopped, this is where it would show.
        Assert.True(taxYears.Single(t => t.TaxYear == 2023).IsLocked, "The 2023 tax year should be locked.");
        Assert.False(taxYears.Single(t => t.TaxYear == 2024).IsLocked);
    }
}

/// <summary>Shared theory data, so every file spells the provider matrix the same way.</summary>
public static class Theories
{
    public static TheoryData<DatabaseProvider> Providers
    {
        get
        {
            var data = new TheoryData<DatabaseProvider>();
            foreach (var provider in ApiFixture.Providers) data.Add(provider);
            return data;
        }
    }
}
