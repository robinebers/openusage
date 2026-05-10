using System.Net.Http.Headers;

namespace UsageMeter.Core.Providers;

public sealed class CodexProvider(WindowsPaths paths, HttpClient httpClient) : ProviderBase(paths, httpClient)
{
    private const string UsageUrl = "https://chatgpt.com/backend-api/wham/usage";

    public override string Id => "codex";
    public override string DisplayName => "Codex";

    protected override async Task<ProviderUsageResult> ProbeCoreAsync(CancellationToken cancellationToken)
    {
        var auth = LoadAuth();
        if (auth.ApiKey is not null)
        {
            throw new InvalidOperationException("Usage is not available for API-key Codex auth. Run `codex login`.");
        }

        if (string.IsNullOrWhiteSpace(auth.AccessToken))
        {
            throw new InvalidOperationException("Not logged in. Run `codex login`.");
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, UsageUrl);
        request.Headers.Authorization = Bearer(auth.AccessToken);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.UserAgent.ParseAdd("UsageMeter/0.1");
        if (!string.IsNullOrWhiteSpace(auth.AccountId))
        {
            request.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", auth.AccountId);
        }

        using var doc = await SendJsonAsync(request, cancellationToken).ConfigureAwait(false);
        var root = doc.RootElement;
        var lines = new List<MetricLine>();

        AddPercentWindow(lines, "Session", root.ObjectProp("rate_limit")?.ObjectProp("primary_window"), TimeSpan.FromHours(5));
        AddPercentWindow(lines, "Weekly", root.ObjectProp("rate_limit")?.ObjectProp("secondary_window"), TimeSpan.FromDays(7));
        AddPercentWindow(lines, "Reviews", root.ObjectProp("code_review_rate_limit")?.ObjectProp("primary_window"), TimeSpan.FromDays(7));

        if (lines.Count == 0)
        {
            lines.Add(MetricLine.Badge("Status", "No usage data", "#737373"));
        }

        return new ProviderUsageResult(Id, DisplayName, PlanLabel(root.StringProp("plan_type")), lines, DateTimeOffset.Now);
    }

    private (string? AccessToken, string? AccountId, string? ApiKey) LoadAuth()
    {
        var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        string[] candidates = string.IsNullOrWhiteSpace(codexHome)
            ? ["~/.codex/auth.json", "~/.config/codex/auth.json"]
            : [Path.Combine(codexHome, "auth.json")];

        using var doc = Json.TryParseDocument(ReadRequiredFile(candidates))
            ?? throw new InvalidOperationException("Codex auth file is invalid. Run `codex login` again.");
        var root = doc.RootElement;
        var tokens = root.ObjectProp("tokens");
        return (tokens?.StringProp("access_token"), tokens?.StringProp("account_id"), root.StringProp("OPENAI_API_KEY"));
    }

    private static void AddPercentWindow(List<MetricLine> lines, string label, System.Text.Json.JsonElement? window, TimeSpan duration)
    {
        var used = window?.NumberProp("used_percent");
        if (used is null)
        {
            return;
        }

        var resetSeconds = window?.NumberProp("reset_at") ?? window?.NumberProp("reset_after_seconds");
        lines.Add(MetricLine.Progress(label, ClampPercent(used.Value), 100, resetsAt: UnixSecondsToDateTime(resetSeconds), periodDuration: duration));
    }

    private static string? PlanLabel(string? plan) => plan?.ToLowerInvariant() switch
    {
        "prolite" => "Pro 5x",
        "pro" => "Pro 20x",
        null or "" => null,
        _ => plan
    };
}
