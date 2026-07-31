using System.Net;
using System.Net.Http.Json;
using CdnTax.Api.Configuration;
using Xunit;

namespace DbParity.Api.Tests;

/// <summary>
/// The write surface, exercised against both engines.
///
/// This is where the two databases are least alike and the API has the most work
/// to do: a native ROWVERSION against a trigger-fed BIGINT, BIT against
/// NUMERIC(1,0), a computed column against a generated one, and constraint
/// violations that arrive as completely different driver errors. Every test below
/// asserts the same observable behaviour regardless of which engine is underneath.
/// </summary>
[Collection(ApiCollection.Name)]
public sealed class WriteEndpointTests(ApiFixture fixture)
{
    public static TheoryData<DatabaseProvider> Providers => Theories.Providers;

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Creating_an_individual_returns_201_with_a_location_and_server_values(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);
        await using var lifecycle = fixture.Lifecycle(provider);

        var code = ClientLifecycle.NewCode("C1");
        var (response, created) = await lifecycle.CreateAsync(ClientLifecycle.Individual(code));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.NotNull(created);
        Assert.Equal($"/api/clients/{created.ClientId}", response.Headers.Location?.ToString());

        Assert.Equal(code, created.ClientCode);
        Assert.Equal("I", created.ClientType);

        // DisplayName is PERSISTED on SQL Server and GENERATED ALWAYS STORED on
        // PostgreSQL. Never written, always read back -- if EF tried to write it,
        // both engines would reject the INSERT outright.
        Assert.Equal("Lovelace, Ada", created.DisplayName);

        // Defaulted by the database on both, so a value here proves the read-back.
        Assert.NotEqual(default, created.CreatedAt);
        Assert.Null(created.UpdatedAt);

        // Native ROWVERSION on one engine, client.tr_client_biu on the other.
        Assert.NotEqual(0, created.RowVersion);

        // And it is really there.
        var fetched = await http.GetFromJsonAsync<ClientJson>($"/api/clients/{created.ClientId}", ApiJson.Options);
        Assert.Equal(created, fetched);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Creating_a_corporation_computes_its_display_name_from_the_legal_name(DatabaseProvider provider)
    {
        await using var lifecycle = fixture.Lifecycle(provider);

        var (response, created) = await lifecycle.CreateAsync(
            ClientLifecycle.Corporation(ClientLifecycle.NewCode("C2")));

        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Equal("Parity Holdings Inc.", created!.DisplayName);

        // TINYINT on SQL Server, SMALLINT on PostgreSQL, byte in the model.
        Assert.Equal((byte)12, created.FiscalYearEndMonth);
        Assert.Equal("123456789", created.BusinessNumber);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Updating_returns_the_new_state_and_a_fresh_rowversion(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);
        await using var lifecycle = fixture.Lifecycle(provider);

        var code = ClientLifecycle.NewCode("U1");
        var (_, created) = await lifecycle.CreateAsync(ClientLifecycle.Individual(code));

        var update = new
        {
            clientCode = code,
            clientType = "I",
            firstName = "Ada",
            lastName = "Byron",
            dateOfBirth = "1815-12-10",
            sin = "046454286",
            maritalStatus = "Married",
            provinceCode = "BC",
            onboardedDate = "2024-02-01",
            isActive = true,
            rowVersion = created!.RowVersion,
        };

        var response = await http.PutAsJsonAsync($"/api/clients/{created.ClientId}", update);
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);

        var updated = await response.Content.ReadFromJsonAsync<ClientJson>(ApiJson.Options);
        Assert.NotNull(updated);
        Assert.Equal("Byron", updated.LastName);
        Assert.Equal("Byron, Ada", updated.DisplayName);   // the generated column recomputed
        Assert.Equal("BC", updated.ProvinceCode);
        Assert.Equal("Married", updated.MaritalStatus);
        Assert.NotNull(updated.UpdatedAt);

        // The concurrency token must move, or the next update could not be rejected.
        Assert.NotEqual(created.RowVersion, updated.RowVersion);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Updating_with_a_stale_rowversion_is_409(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);
        await using var lifecycle = fixture.Lifecycle(provider);

        var code = ClientLifecycle.NewCode("U2");
        var (_, created) = await lifecycle.CreateAsync(ClientLifecycle.Individual(code));

        object Body(long rowVersion) => new
        {
            clientCode = code,
            clientType = "I",
            firstName = "Ada",
            lastName = "Lovelace",
            dateOfBirth = "1815-12-10",
            sin = "046454286",
            maritalStatus = "Single",
            provinceCode = "ON",
            onboardedDate = "2024-02-01",
            isActive = true,
            rowVersion,
        };

        // First write succeeds and moves the token.
        var first = await http.PutAsJsonAsync($"/api/clients/{created!.ClientId}", Body(created.RowVersion));
        Assert.Equal(HttpStatusCode.OK, first.StatusCode);

        // Replaying the original token is the classic lost-update attempt. Optimistic
        // concurrency is the single most provider-specific mechanism in the API --
        // SQL Server's engine-maintained ROWVERSION versus a trigger and a sequence
        // on PostgreSQL -- and it has to produce the same 409 on both.
        var second = await http.PutAsJsonAsync($"/api/clients/{created.ClientId}", Body(created.RowVersion));
        Assert.Equal(HttpStatusCode.Conflict, second.StatusCode);

        // The 409 carries the current state so a caller can merge and retry.
        var body = await second.Content.ReadFromJsonAsync<ConcurrencyConflict>(ApiJson.Options);
        Assert.NotNull(body?.Current);
        Assert.Equal(created.ClientId, body.Current.ClientId);
        Assert.NotEqual(created.RowVersion, body.Current.RowVersion);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Deleting_removes_the_client(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);
        await using var lifecycle = fixture.Lifecycle(provider);

        var (_, created) = await lifecycle.CreateAsync(
            ClientLifecycle.Individual(ClientLifecycle.NewCode("D1")));

        var deleted = await http.DeleteAsync($"/api/clients/{created!.ClientId}");
        Assert.Equal(HttpStatusCode.NoContent, deleted.StatusCode);
        lifecycle.Forget(created.ClientId);

        var fetched = await http.GetAsync($"/api/clients/{created.ClientId}");
        Assert.Equal(HttpStatusCode.NotFound, fetched.StatusCode);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task Updating_or_deleting_an_unknown_client_is_404(DatabaseProvider provider)
    {
        var http = fixture.Client(provider);

        var update = await http.PutAsJsonAsync("/api/clients/999999", ClientLifecycle.Individual("APITEST-NOPE"));
        Assert.Equal(HttpStatusCode.NotFound, update.StatusCode);

        var delete = await http.DeleteAsync("/api/clients/999999");
        Assert.Equal(HttpStatusCode.NotFound, delete.StatusCode);
    }

    // --- validation, ahead of the database -------------------------------

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task An_individual_carrying_corporate_fields_is_400(DatabaseProvider provider)
    {
        // CK_Client_TypeShape would reject this too, but as an opaque constraint
        // error naming no field. ClientValidation turns it into a field-level 400,
        // identically on both providers -- that is the behaviour being pinned.
        var response = await fixture.Client(provider).PostAsJsonAsync("/api/clients", new
        {
            clientCode = ClientLifecycle.NewCode("V1"),
            clientType = "I",
            firstName = "X",
            lastName = "Y",
            dateOfBirth = "1990-01-01",
            legalName = "Corporations only",
            provinceCode = "ON",
            onboardedDate = "2024-02-01",
        });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);

        var problem = await response.Content.ReadFromJsonAsync<ValidationProblem>(ApiJson.Options);
        Assert.NotNull(problem?.Errors);
        Assert.Contains("legalName", problem.Errors.Keys, StringComparer.OrdinalIgnoreCase);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task An_unknown_client_type_is_400(DatabaseProvider provider)
    {
        var response = await fixture.Client(provider).PostAsJsonAsync("/api/clients", new
        {
            clientCode = ClientLifecycle.NewCode("V2"),
            clientType = "X",
            provinceCode = "ON",
            onboardedDate = "2024-02-01",
        });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);

        var problem = await response.Content.ReadFromJsonAsync<ValidationProblem>(ApiJson.Options);
        Assert.Contains("clientType", problem!.Errors.Keys, StringComparer.OrdinalIgnoreCase);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task A_malformed_sin_is_400(DatabaseProvider provider)
    {
        var response = await fixture.Client(provider).PostAsJsonAsync("/api/clients", new
        {
            clientCode = ClientLifecycle.NewCode("V3"),
            clientType = "I",
            firstName = "Ada",
            lastName = "Lovelace",
            dateOfBirth = "1815-12-10",
            sin = "12345",
            provinceCode = "ON",
            onboardedDate = "2024-02-01",
        });

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);

        var problem = await response.Content.ReadFromJsonAsync<ValidationProblem>(ApiJson.Options);
        Assert.Contains("sin", problem!.Errors.Keys, StringComparer.OrdinalIgnoreCase);
    }

    // --- constraints, from the database ----------------------------------

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task A_duplicate_client_code_is_409(DatabaseProvider provider)
    {
        await using var lifecycle = fixture.Lifecycle(provider);

        var code = ClientLifecycle.NewCode("X1");
        var (first, _) = await lifecycle.CreateAsync(ClientLifecycle.Individual(code));
        Assert.Equal(HttpStatusCode.Created, first.StatusCode);

        // UQ_Client_ClientCode. SqlException 2627 on one engine, SQLSTATE 23505 on
        // the other; DbErrorTranslator is what makes both answer 409.
        var (second, _) = await lifecycle.CreateAsync(ClientLifecycle.Individual(code));
        Assert.Equal(HttpStatusCode.Conflict, second.StatusCode);
    }

    [Theory]
    [MemberData(nameof(Providers))]
    public async Task An_unknown_province_is_400(DatabaseProvider provider)
    {
        await using var lifecycle = fixture.Lifecycle(provider);

        // FK_Client_Province. SQL Server reports 547 for foreign keys AND check
        // constraints, so the translator has to read the constraint name out of the
        // message to tell them apart; PostgreSQL has a dedicated 23503.
        var (response, _) = await lifecycle.CreateAsync(
            ClientLifecycle.Individual(ClientLifecycle.NewCode("X2"), province: "ZZ"));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    private sealed record ConcurrencyConflict(string Title, string Detail, ClientJson? Current);

    private sealed record ValidationProblem(string? Title, int? Status, Dictionary<string, string[]> Errors);
}
