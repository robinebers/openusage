using System.Text.Json;

namespace UsageMeter.Core;

internal static class Json
{
    public static readonly JsonSerializerOptions WebOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true
    };

    public static JsonDocument? TryParseDocument(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        try
        {
            return JsonDocument.Parse(text);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string? StringProp(this JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    public static double? NumberProp(this JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value))
        {
            return null;
        }

        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number))
        {
            return number;
        }

        return value.ValueKind == JsonValueKind.String && double.TryParse(value.GetString(), out number) ? number : null;
    }

    public static JsonElement? ObjectProp(this JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Object ? value : null;
}
