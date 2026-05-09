using System.Diagnostics;

namespace UsageMeter.Core.Providers;

public sealed class ClaudeProvider(WindowsPaths paths, HttpClient httpClient) : ProviderBase(paths, httpClient)
{
    private const string UsageUrl = "https://api.anthropic.com/api/oauth/usage";

    public override string Id => "claude";
    public override string DisplayName => "Claude";

    protected override async Task<ProviderUsageResult> ProbeCoreAsync(CancellationToken cancellationToken)
    {
        var token = Environment.GetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN") ?? LoadAccessTokenFromFile();
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new InvalidOperationException("Not logged in. Run `claude` to authenticate.");
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, UsageUrl);
        request.Headers.Authorization = Bearer(token);
        request.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
        request.Headers.TryAddWithoutValidation("User-Agent", "claude-code/2.1.69");

        using var doc = await SendJsonAsync(request, cancellationToken).ConfigureAwait(false);
        var root = doc.RootElement;
        var lines = new List<MetricLine>();
        AddUtilization(lines, "Session", root.ObjectProp("five_hour"), TimeSpan.FromHours(5));
        AddUtilization(lines, "Weekly", root.ObjectProp("seven_day"), TimeSpan.FromDays(7));
        AddUtilization(lines, "Sonnet", root.ObjectProp("seven_day_sonnet"), TimeSpan.FromDays(7));
        if (lines.Count == 0)
        {
            lines.Add(MetricLine.Badge("Status", "No usage data", "#737373"));
        }

        return new ProviderUsageResult(Id, DisplayName, null, lines, DateTimeOffset.Now);
    }

    private string? LoadAccessTokenFromFile()
    {
        var configured = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        var credentialsPath = string.IsNullOrWhiteSpace(configured) ? "~/.claude/.credentials.json" : Path.Combine(configured, ".credentials.json");
        using var doc = Json.TryParseDocument(ReadRequiredFile(credentialsPath));
        return doc?.RootElement.ObjectProp("claudeAiOauth")?.StringProp("accessToken");
    }

    private static void AddUtilization(List<MetricLine> lines, string label, System.Text.Json.JsonElement? value, TimeSpan duration)
    {
        var used = value?.NumberProp("utilization");
        if (used is null)
        {
            return;
        }

        var reset = DateTimeOffset.TryParse(value?.StringProp("resets_at"), out var parsed) ? parsed : (DateTimeOffset?)null;
        lines.Add(MetricLine.Progress(label, ClampPercent(used.Value), 100, resetsAt: reset, periodDuration: duration));
    }
}

public sealed class CopilotProvider(WindowsPaths paths, HttpClient httpClient) : ProviderBase(paths, httpClient)
{
    private const string UsageUrl = "https://api.github.com/copilot_internal/user";

    public override string Id => "copilot";
    public override string DisplayName => "Copilot";

    protected override async Task<ProviderUsageResult> ProbeCoreAsync(CancellationToken cancellationToken)
    {
        var token = await ReadGhTokenAsync(cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new InvalidOperationException("Not logged in. Run `gh auth login` first.");
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, UsageUrl);
        request.Headers.TryAddWithoutValidation("Authorization", "token " + token);
        request.Headers.TryAddWithoutValidation("Accept", "application/json");
        request.Headers.TryAddWithoutValidation("User-Agent", "UsageMeter");
        request.Headers.TryAddWithoutValidation("Editor-Version", "vscode/1.96.2");
        request.Headers.TryAddWithoutValidation("Editor-Plugin-Version", "copilot-chat/0.26.7");

        using var doc = await SendJsonAsync(request, cancellationToken).ConfigureAwait(false);
        var root = doc.RootElement;
        var lines = new List<MetricLine>();
        var snapshots = root.ObjectProp("quota_snapshots");
        AddRemainingLine(lines, "Premium", snapshots?.ObjectProp("premium_interactions"), root.StringProp("quota_reset_date"));
        AddRemainingLine(lines, "Chat", snapshots?.ObjectProp("chat"), root.StringProp("quota_reset_date"));
        if (lines.Count == 0)
        {
            lines.Add(MetricLine.Badge("Status", "No usage data", "#737373"));
        }

        return new ProviderUsageResult(Id, DisplayName, root.StringProp("copilot_plan"), lines, DateTimeOffset.Now);
    }

    private static async Task<string?> ReadGhTokenAsync(CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo("gh", "auth token")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return null;
            }
            var output = await process.StandardOutput.ReadToEndAsync(cancellationToken).ConfigureAwait(false);
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            return process.ExitCode == 0 ? output.Trim() : null;
        }
        catch
        {
            return null;
        }
    }

    private static void AddRemainingLine(List<MetricLine> lines, string label, System.Text.Json.JsonElement? snapshot, string? resetDate)
    {
        var remaining = snapshot?.NumberProp("percent_remaining");
        if (remaining is null)
        {
            return;
        }

        var reset = DateTimeOffset.TryParse(resetDate, out var parsed) ? parsed : (DateTimeOffset?)null;
        lines.Add(MetricLine.Progress(label, ClampPercent(100 - remaining.Value), 100, resetsAt: reset, periodDuration: TimeSpan.FromDays(30)));
    }
}
