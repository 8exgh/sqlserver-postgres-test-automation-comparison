using System.Text.Json;
using System.Text.Json.Nodes;

namespace DbParity.Core.Results;

/// <summary>
/// Rewrites a JSON document into a canonical form -- object keys sorted, no
/// insignificant whitespace -- so two documents that mean the same thing compare
/// as the same string.
///
/// Needed because the two engines store JSON differently by design: SQL Server
/// keeps the NVARCHAR text exactly as FOR JSON produced it, while the port uses
/// jsonb, which parses on the way in and reserializes with its own key order. The
/// audit trail is identical as data and different as text, and comparing the text
/// would report a difference on every audit row while saying nothing true.
///
/// Array order is preserved: in JSON that IS significant, and flattening it would
/// hide a real defect.
/// </summary>
public static class JsonCanonicalizer
{
    /// <summary>
    /// Returns the canonical form, or the input unchanged when it is not valid JSON
    /// -- a column wrongly marked as JSON should surface as a value difference, not
    /// as an exception from inside the comparer.
    /// </summary>
    public static string Canonicalize(string json)
    {
        try
        {
            var node = JsonNode.Parse(json);
            return node is null ? "null" : Write(node);
        }
        catch (JsonException)
        {
            return json;
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
