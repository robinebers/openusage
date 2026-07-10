using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenUsageShell;

/// <summary>
/// Minimal update-check stub for Phase 5. Fetches a JSON feed and compares versions.
/// Production will likely use Velopack or WinSparkle — see docs/research/windows-phase5-findings.md.
/// </summary>
internal sealed class UpdateChecker
{
    /// <summary>
    /// Placeholder feed URL on gh-pages (not published until release-windows lands).
    /// Override with OPENUSAGE_UPDATE_FEED for local testing.
    /// </summary>
    public const string DefaultFeedUrl = "https://robinebers.github.io/openusage/windows-update.json";

    private static readonly HttpClient Http = new()
    {
        Timeout = TimeSpan.FromSeconds(15)
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    public async Task<UpdateInfo?> CheckForUpdateAsync(CancellationToken cancellationToken = default)
    {
        var feedUrl = Environment.GetEnvironmentVariable("OPENUSAGE_UPDATE_FEED");
        if (string.IsNullOrWhiteSpace(feedUrl))
        {
            feedUrl = DefaultFeedUrl;
        }

        using var response = await Http.GetAsync(feedUrl, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            ShellLogger.Instance.Warn("updater", $"Feed returned {(int)response.StatusCode} from {feedUrl}");
            return null;
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        var feed = await JsonSerializer.DeserializeAsync<UpdateFeed>(stream, JsonOptions, cancellationToken).ConfigureAwait(false);
        if (feed is null || string.IsNullOrWhiteSpace(feed.Version) || string.IsNullOrWhiteSpace(feed.Url))
        {
            ShellLogger.Instance.Warn("updater", "Feed missing required version or url fields");
            return null;
        }

        var localVersion = GetLocalVersion();
        if (!IsRemoteNewer(localVersion, feed.Version))
        {
            ShellLogger.Instance.Info("updater", $"No update (local={localVersion}, remote={feed.Version})");
            return null;
        }

        ShellLogger.Instance.Info("updater", $"Update available: {feed.Version} (local={localVersion})");
        return new UpdateInfo(feed.Version, feed.Url, feed.Sha256, feed.Channel);
    }

    public static string GetLocalVersion()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(informational))
        {
            var plus = informational.IndexOf('+');
            return plus >= 0 ? informational[..plus] : informational;
        }

        return assembly.GetName().Version?.ToString(3) ?? "0.0.0";
    }

    internal static bool IsRemoteNewer(string local, string remote)
    {
        try
        {
            return ParseVersion(remote) > ParseVersion(local);
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("updater", $"Version compare failed for local={local} remote={remote}: {ex.Message}");
            return false;
        }
    }

    private static Version ParseVersion(string value)
    {
        var trimmed = value.Trim();
        var dash = trimmed.IndexOf('-');
        if (dash >= 0)
        {
            trimmed = trimmed[..dash];
        }

        var parts = trimmed.Split('.');
        if (parts.Length < 4)
        {
            trimmed = string.Join('.', parts.Concat(Enumerable.Repeat("0", 4 - parts.Length)));
        }

        return Version.Parse(trimmed);
    }

    public static void OpenDownloadUrl(string url)
    {
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }
}

internal sealed record UpdateInfo(string Version, string Url, string? Sha256, string? Channel);

internal sealed class UpdateFeed
{
    [JsonPropertyName("version")]
    public string? Version { get; set; }

    [JsonPropertyName("url")]
    public string? Url { get; set; }

    [JsonPropertyName("sha256")]
    public string? Sha256 { get; set; }

    [JsonPropertyName("channel")]
    public string? Channel { get; set; }
}
