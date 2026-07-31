using System.Text.Json;
using System.Text.Json.Nodes;

namespace DbParity.Api.Tests;

/// <summary>
/// The wire shape of a client, declared here rather than reused from
/// <c>CdnTax.Api.Dtos.ClientResponse</c>.
///
/// That duplication is deliberate: these are contract tests. If someone renames a
/// property on the production DTO, the JSON its consumers receive changes, and a
/// test that shared the type would happily rename with it and never notice.
/// </summary>
public sealed record ClientJson(
    int ClientId,
    string ClientCode,
    string ClientType,
    string DisplayName,
    string? FirstName,
    string? LastName,
    DateOnly? DateOfBirth,
    string? Sin,
    string? MaritalStatus,
    string? LegalName,
    DateOnly? IncorporationDate,
    string? BusinessNumber,
    byte? FiscalYearEndMonth,
    string ProvinceCode,
    DateOnly OnboardedDate,
    bool IsActive,
    DateTime CreatedAt,
    DateTime? UpdatedAt,
    long RowVersion);

public sealed record EngagementJson(
    int EngagementId,
    int ClientId,
    short TaxYear,
    string ServiceType,
    int? PractitionerId,
    string? PractitionerName,
    string Status,
    decimal? FeeQuoted,
    decimal? FeeBilled,
    DateOnly? StartedOn,
    DateOnly? CompletedOn);

public sealed record HealthJson(
    string Provider,
    string? DataSource,
    string? Database,
    bool CanConnect,
    int ClientCount);

public sealed record ProvinceJson(string ProvinceCode, string ProvinceName, bool IsTerritory, byte SortOrder);

public sealed record PractitionerJson(
    int PractitionerId, string FullName, string? Designation, string Email, bool IsPartner, bool IsActive);

public sealed record TaxYearJson(
    short TaxYear,
    DateOnly T1FilingDeadline,
    DateOnly SelfEmployedDeadline,
    DateOnly RrspDeadline,
    decimal InstallmentThreshold,
    bool IsLocked);

/// <summary>
/// Helpers for comparing two JSON documents that should be the same.
/// </summary>
public static class ApiJson
{
    /// <summary>Minimal APIs serialize with the web defaults, so tests read them back the same way.</summary>
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// Canonical rendering: object keys sorted, no insignificant whitespace. Two
    /// documents carrying the same facts then compare as the same string, so a
    /// failure names the payload rather than a property ordering.
    ///
    /// Array order is preserved -- in JSON that is significant, and every list
    /// endpoint here has an explicit ORDER BY, so a reordering is a real difference.
    /// </summary>
    public static string Canonical(string json)
    {
        var node = JsonNode.Parse(json);
        return node is null ? "null" : Write(node);
    }

    /// <summary>
    /// As <see cref="Canonical"/>, but first removes the named properties wherever
    /// they appear. For write responses, where a handful of fields cannot match
    /// across two independently-writing databases.
    /// </summary>
    public static string CanonicalWithout(string json, params string[] propertyNames)
    {
        var node = JsonNode.Parse(json);
        if (node is null) return "null";

        var drop = propertyNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
        Strip(node, drop);
        return Write(node);
    }

    private static void Strip(JsonNode node, IReadOnlySet<string> drop)
    {
        switch (node)
        {
            case JsonObject obj:
                foreach (var key in obj.Select(p => p.Key).Where(drop.Contains).ToArray()) obj.Remove(key);
                foreach (var child in obj.Select(p => p.Value).OfType<JsonNode>().ToArray()) Strip(child, drop);
                break;

            case JsonArray array:
                foreach (var item in array.OfType<JsonNode>().ToArray()) Strip(item, drop);
                break;
        }
    }

    private static string Write(JsonNode node)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = false }))
        {
            WriteNode(writer, node);
        }
        return System.Text.Encoding.UTF8.GetString(stream.ToArray());
    }

    private static void WriteNode(Utf8JsonWriter writer, JsonNode? node)
    {
        switch (node)
        {
            case null:
                writer.WriteNullValue();
                break;

            case JsonObject obj:
                writer.WriteStartObject();
                foreach (var property in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Key);
                    WriteNode(writer, property.Value);
                }
                writer.WriteEndObject();
                break;

            case JsonArray array:
                writer.WriteStartArray();
                foreach (var item in array) WriteNode(writer, item);
                writer.WriteEndArray();
                break;

            default:
                node.AsValue().WriteTo(writer);
                break;
        }
    }
}
