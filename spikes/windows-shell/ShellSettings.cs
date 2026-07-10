using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenUsageShell;

internal sealed class ShellSettings
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    [JsonPropertyName("launchAtLogin")]
    public bool LaunchAtLogin { get; set; }

    [JsonPropertyName("stripLeft")]
    public double? StripLeft { get; set; }

    [JsonPropertyName("stripTop")]
    public double? StripTop { get; set; }

    /// <summary>
    /// Dedupe keys for quota toasts, e.g. "claude:Session".
    /// </summary>
    [JsonPropertyName("quotaToastDedupeKeys")]
    public List<string> QuotaToastDedupeKeys { get; set; } = [];

    public static ShellSettings Load()
    {
        ShellPaths.EnsureDirectories();
        try
        {
            if (!File.Exists(ShellPaths.SettingsPath))
            {
                return new ShellSettings();
            }

            var json = File.ReadAllText(ShellPaths.SettingsPath);
            return JsonSerializer.Deserialize<ShellSettings>(json, JsonOptions) ?? new ShellSettings();
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("settings", $"Failed to load settings: {ex.Message}");
            return new ShellSettings();
        }
    }

    public void Save()
    {
        ShellPaths.EnsureDirectories();
        try
        {
            var json = JsonSerializer.Serialize(this, JsonOptions);
            File.WriteAllText(ShellPaths.SettingsPath, json);
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Error("settings", "Failed to save settings", ex);
        }
    }

    public bool ShouldShowQuotaToast(string dedupeKey)
    {
        return !QuotaToastDedupeKeys.Contains(dedupeKey, StringComparer.OrdinalIgnoreCase);
    }

    public void MarkQuotaToastShown(string dedupeKey)
    {
        if (!QuotaToastDedupeKeys.Contains(dedupeKey, StringComparer.OrdinalIgnoreCase))
        {
            QuotaToastDedupeKeys.Add(dedupeKey);
            Save();
        }
    }
}
