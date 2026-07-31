using System.Net.Http.Json;
using CdnTax.Api.Configuration;
using Xunit;

namespace DbParity.Api.Tests;

/// <summary>
/// A client that deletes itself.
///
/// These tests write to a real database over HTTP, so unlike the DbParity suites
/// there is no transaction to roll back -- the request has committed by the time
/// the response arrives. Every created row is therefore removed in
/// <see cref="DisposeAsync"/>, whether the test passed or threw, which is what
/// keeps the fixture byte-identical for the cross-engine comparisons that follow.
///
/// One thing is deliberately left behind: audit.ChangeLog rows. That table is
/// append-only and records these creations permanently, exactly as db/README.md
/// describes for 099_verify.sql's own scratch clients. It is the audit trail
/// working, not drift.
/// </summary>
public sealed class ClientLifecycle(HttpClient http) : IAsyncDisposable
{
    private readonly List<int> _created = [];

    /// <summary>
    /// A code unique to this run, inside the prefix the fixture cleans up.
    ///
    /// ClientCode is NVARCHAR(20) with a unique constraint, so the budget is fixed:
    /// the 8-character prefix, a short discriminator, and the rest random. The
    /// random part is never truncated -- doing so would let two tests collide on
    /// UQ_Client_ClientCode and fail for a reason unrelated to what they assert.
    /// </summary>
    public static string NewCode(string discriminator)
    {
        const int maxLength = 20;
        const int minimumRandom = 6;

        var room = maxLength - ApiFixture.TestCodePrefix.Length - discriminator.Length;
        if (room < minimumRandom)
        {
            throw new ArgumentException(
                $"Discriminator '{discriminator}' leaves only {room} characters for uniqueness; " +
                $"ClientCode is limited to {maxLength}. Use a shorter one.",
                nameof(discriminator));
        }

        var suffix = Guid.NewGuid().ToString("N")[..Math.Min(room, 8)].ToUpperInvariant();
        return ApiFixture.TestCodePrefix + discriminator + suffix;
    }

    /// <summary>An individual that satisfies CK_Client_TypeShape and every validation rule.</summary>
    public static object Individual(string clientCode, string province = "ON", bool active = true) => new
    {
        clientCode,
        clientType = "I",
        firstName = "Ada",
        lastName = "Lovelace",
        dateOfBirth = "1815-12-10",
        sin = "046454286",
        maritalStatus = "Single",
        provinceCode = province,
        onboardedDate = "2024-02-01",
        isActive = active,
    };

    /// <summary>A corporation, which requires the other half of CK_Client_TypeShape.</summary>
    public static object Corporation(string clientCode, string province = "ON") => new
    {
        clientCode,
        clientType = "C",
        legalName = "Parity Holdings Inc.",
        incorporationDate = "2010-03-01",
        businessNumber = "123456789",
        fiscalYearEndMonth = 12,
        provinceCode = province,
        onboardedDate = "2024-02-01",
        isActive = true,
    };

    /// <summary>POSTs the body and registers whatever it created for cleanup.</summary>
    public async Task<(HttpResponseMessage Response, ClientJson? Client)> CreateAsync(object body)
    {
        var response = await http.PostAsJsonAsync("/api/clients", body);
        if (!response.IsSuccessStatusCode) return (response, null);

        var created = await response.Content.ReadFromJsonAsync<ClientJson>(ApiJson.Options);
        if (created is not null) _created.Add(created.ClientId);
        return (response, created);
    }

    /// <summary>Registers a row this instance did not create, so a test can hand over ownership.</summary>
    public void Track(int clientId) => _created.Add(clientId);

    /// <summary>Forgets a row, for a test that deleted it as the thing under test.</summary>
    public void Forget(int clientId) => _created.Remove(clientId);

    public async ValueTask DisposeAsync()
    {
        foreach (var id in _created)
        {
            try
            {
                await http.DeleteAsync($"/api/clients/{id}");
            }
            catch (HttpRequestException)
            {
                // Cleanup must never mask the assertion that actually failed.
            }
        }
    }
}

/// <summary>Convenience so a test reads <c>fixture.Lifecycle(provider)</c>.</summary>
public static class ApiFixtureExtensions
{
    public static ClientLifecycle Lifecycle(this ApiFixture fixture, DatabaseProvider provider) =>
        new(fixture.Client(provider));
}
