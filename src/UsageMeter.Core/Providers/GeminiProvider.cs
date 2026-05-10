using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace UsageMeter.Core.Providers;

public sealed class GeminiProvider(WindowsPaths paths, HttpClient httpClient) : ProviderBase(paths, httpClient)
{
    private const string SettingsPath = "~/.gemini/settings.json";
    private const string CredsPath = "~/.gemini/oauth_creds.json";
    private const string LoadCodeAssistUrl = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
    private const string QuotaUrl = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota";
    private const string ProjectsUrl = "https://cloudresourcemanager.googleapis.com/v1/projects";
    private const string TokenUrl = "https://oauth2.googleapis.com/token";
    private static readonly TimeSpan RefreshBuffer = TimeSpan.FromMinutes(5);

    public override string Id => "gemini";
    public override string DisplayName => "Gemini";

    protected override async Task<ProviderUsageResult> ProbeCoreAsync(CancellationToken cancellationToken)
    {
        AssertSupportedAuthType();

        var credsPath = Paths.Expand(CredsPath);
        var creds = LoadCreds(credsPath);
        var accessToken = creds["access_token"]?.GetValue<string>();
        if (NeedsRefresh(creds))
        {
            accessToken = await RefreshTokenAsync(credsPath, creds, cancellationToken).ConfigureAwait(false) ?? accessToken;
        }

        if (string.IsNullOrWhiteSpace(accessToken))
        {
            throw new InvalidOperationException("Not logged in. Run `gemini` and complete the OAuth prompt.");
        }

        var idToken = DecodeIdToken(creds["id_token"]?.GetValue<string>());
        var loadCodeAssist = await PostGeminiJsonAsync(LoadCodeAssistUrl, accessToken, new
        {
            metadata = new
            {
                ideType = "IDE_UNSPECIFIED",
                platform = "PLATFORM_UNSPECIFIED",
                pluginType = "GEMINI",
                duetProject = "default"
            }
        }, cancellationToken).ConfigureAwait(false);

        var tier = ReadFirstStringDeep(loadCodeAssist.RootElement, ["tier", "userTier", "subscriptionTier"]);
        var plan = MapTierToPlan(tier, idToken);
        var projectId = await DiscoverProjectIdAsync(accessToken, loadCodeAssist.RootElement, cancellationToken).ConfigureAwait(false);
        using var quota = await PostGeminiJsonAsync(QuotaUrl, accessToken, projectId is null ? new { } : new { project = projectId }, cancellationToken).ConfigureAwait(false);

        var lines = ParseQuotaLines(quota.RootElement);
        if (idToken.TryGetValue("email", out var email) && !string.IsNullOrWhiteSpace(email))
        {
            lines.Add(MetricLine.Text("Account", email));
        }
        if (lines.Count == 0)
        {
            lines.Add(MetricLine.Badge("Status", "No usage data", "#737373"));
        }

        return new ProviderUsageResult(Id, DisplayName, plan, lines, DateTimeOffset.Now);
    }

    private void AssertSupportedAuthType()
    {
        using var settings = Json.TryParseDocument(File.Exists(Paths.Expand(SettingsPath))
            ? File.ReadAllText(Paths.Expand(SettingsPath))
            : "{}");
        var authType = settings?.RootElement.StringProp("authType");
        if (!string.IsNullOrWhiteSpace(authType) && !authType.Equals("oauth-personal", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Gemini auth type {authType} is not supported yet.");
        }
    }

    private JsonObject LoadCreds(string credsPath)
    {
        if (!File.Exists(credsPath))
        {
            throw new InvalidOperationException("Not logged in. Run `gemini` and complete the OAuth prompt.");
        }

        var node = JsonNode.Parse(File.ReadAllText(credsPath)) as JsonObject;
        if (node is null || (node["access_token"] is null && node["refresh_token"] is null))
        {
            throw new InvalidOperationException("Not logged in. Run `gemini` and complete the OAuth prompt.");
        }

        return node;
    }

    private static bool NeedsRefresh(JsonObject creds)
    {
        if (creds["access_token"] is null)
        {
            return true;
        }

        var expiryNode = creds["expiry_date"];
        if (expiryNode is null)
        {
            return false;
        }

        var expiry = expiryNode.GetValue<double>();
        var expiryMs = expiry > 10_000_000_000 ? expiry : expiry * 1000;
        return DateTimeOffset.UtcNow.Add(RefreshBuffer).ToUnixTimeMilliseconds() >= expiryMs;
    }

    private async Task<string?> RefreshTokenAsync(string credsPath, JsonObject creds, CancellationToken cancellationToken)
    {
        var refreshToken = creds["refresh_token"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(refreshToken))
        {
            return null;
        }

        var clientCreds = LoadOauthClientCreds();
        if (clientCreds is null)
        {
            return null;
        }

        using var response = await Http.PostAsync(TokenUrl, new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["client_id"] = clientCreds.Value.ClientId,
            ["client_secret"] = clientCreds.Value.ClientSecret,
            ["refresh_token"] = refreshToken,
            ["grant_type"] = "refresh_token"
        }), cancellationToken).ConfigureAwait(false);

        if (response.StatusCode is System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden)
        {
            throw new InvalidOperationException("Gemini session expired. Run `gemini` and re-authenticate when prompted.");
        }
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        var node = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false)) as JsonObject;
        var accessToken = node?["access_token"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(accessToken))
        {
            return null;
        }

        creds["access_token"] = accessToken;
        if (node?["id_token"]?.GetValue<string>() is { Length: > 0 } idToken)
        {
            creds["id_token"] = idToken;
        }
        if (node?["refresh_token"]?.GetValue<string>() is { Length: > 0 } newRefreshToken)
        {
            creds["refresh_token"] = newRefreshToken;
        }
        if (node?["expires_in"]?.GetValue<double>() is { } expiresIn)
        {
            creds["expiry_date"] = DateTimeOffset.UtcNow.AddSeconds(expiresIn).ToUnixTimeMilliseconds();
        }

        File.WriteAllText(credsPath, creds.ToJsonString(Json.WebOptions));
        return accessToken;
    }

    private (string ClientId, string ClientSecret)? LoadOauthClientCreds()
    {
        foreach (var candidate in BuildOauthCandidatePaths())
        {
            var path = Paths.Expand(candidate);
            if (!File.Exists(path))
            {
                continue;
            }

            var text = File.ReadAllText(path);
            var id = Regex.Match(text, "OAUTH_CLIENT_ID\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]");
            var secret = Regex.Match(text, "OAUTH_CLIENT_SECRET\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]");
            if (id.Success && secret.Success)
            {
                return (id.Groups[1].Value, secret.Groups[1].Value);
            }
        }

        return null;
    }

    private IEnumerable<string> BuildOauthCandidatePaths()
    {
        string[] roots =
        [
            "%APPDATA%/npm/node_modules",
            "%LOCALAPPDATA%/pnpm/global/5/node_modules",
            "%USERPROFILE%/.npm-global/lib/node_modules",
            "%USERPROFILE%/.volta/tools/image/packages/@google/gemini-cli/lib/node_modules"
        ];

        foreach (var root in roots)
        {
            yield return root + "/@google/gemini-cli-core/dist/src/code_assist/oauth2.js";
            yield return root + "/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js";
        }
    }

    private async Task<JsonDocument> PostGeminiJsonAsync(string url, string accessToken, object body, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Authorization = Bearer(accessToken);
        request.Headers.Accept.ParseAdd("application/json");
        request.Content = JsonContent(body);
        using var response = await Http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var text = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (response.StatusCode is System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden)
        {
            throw new InvalidOperationException("Gemini session expired. Run `gemini` and re-authenticate when prompted.");
        }
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Gemini quota request failed (HTTP {(int)response.StatusCode}). Try again later.");
        }

        return JsonDocument.Parse(text);
    }

    private async Task<string?> DiscoverProjectIdAsync(string accessToken, JsonElement loadCodeAssist, CancellationToken cancellationToken)
    {
        var fromLoadCodeAssist = ReadFirstStringDeep(loadCodeAssist, ["cloudaicompanionProject"]);
        if (!string.IsNullOrWhiteSpace(fromLoadCodeAssist))
        {
            return fromLoadCodeAssist;
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, ProjectsUrl);
        request.Headers.Authorization = Bearer(accessToken);
        request.Headers.Accept.ParseAdd("application/json");
        using var response = await Http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            return null;
        }

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false));
        if (!doc.RootElement.TryGetProperty("projects", out var projects) || projects.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        foreach (var project in projects.EnumerateArray())
        {
            var projectId = project.StringProp("projectId");
            if (string.IsNullOrWhiteSpace(projectId))
            {
                continue;
            }

            if (projectId.StartsWith("gen-lang-client", StringComparison.OrdinalIgnoreCase))
            {
                return projectId;
            }
            if (project.ObjectProp("labels")?.TryGetProperty("generative-language", out _) == true)
            {
                return projectId;
            }
        }

        return null;
    }

    private static Dictionary<string, string> DecodeIdToken(string? token)
    {
        if (string.IsNullOrWhiteSpace(token))
        {
            return [];
        }

        try
        {
            var payload = token.Split('.')[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + ((4 - payload.Length % 4) % 4), '=');
            var json = Encoding.UTF8.GetString(Convert.FromBase64String(payload));
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.EnumerateObject()
                .Where(property => property.Value.ValueKind == JsonValueKind.String)
                .ToDictionary(property => property.Name, property => property.Value.GetString() ?? string.Empty);
        }
        catch
        {
            return [];
        }
    }

    private static string? ReadFirstStringDeep(JsonElement element, string[] keys)
    {
        if (element.ValueKind != JsonValueKind.Object && element.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var property in element.EnumerateObject())
            {
                if (keys.Contains(property.Name) && property.Value.ValueKind == JsonValueKind.String)
                {
                    return property.Value.GetString();
                }

                var nested = ReadFirstStringDeep(property.Value, keys);
                if (!string.IsNullOrWhiteSpace(nested))
                {
                    return nested;
                }
            }
        }
        else
        {
            foreach (var item in element.EnumerateArray())
            {
                var nested = ReadFirstStringDeep(item, keys);
                if (!string.IsNullOrWhiteSpace(nested))
                {
                    return nested;
                }
            }
        }

        return null;
    }

    private static string? MapTierToPlan(string? tier, IReadOnlyDictionary<string, string> idToken)
    {
        return tier?.Trim().ToLowerInvariant() switch
        {
            "standard-tier" => "Paid",
            "legacy-tier" => "Legacy",
            "free-tier" => idToken.ContainsKey("hd") ? "Workspace" : "Free",
            _ => null
        };
    }

    private static List<MetricLine> ParseQuotaLines(JsonElement quota)
    {
        var buckets = new List<QuotaBucket>();
        CollectQuotaBuckets(quota, buckets);
        var lines = new List<MetricLine>();

        AddLowestRemaining(lines, "Pro", buckets.Where(bucket => bucket.ModelId.Contains("gemini", StringComparison.OrdinalIgnoreCase) && bucket.ModelId.Contains("pro", StringComparison.OrdinalIgnoreCase)));
        AddLowestRemaining(lines, "Flash", buckets.Where(bucket => bucket.ModelId.Contains("gemini", StringComparison.OrdinalIgnoreCase) && bucket.ModelId.Contains("flash", StringComparison.OrdinalIgnoreCase)));
        return lines;
    }

    private static void AddLowestRemaining(List<MetricLine> lines, string label, IEnumerable<QuotaBucket> buckets)
    {
        var bucket = buckets.MinBy(value => value.RemainingFraction);
        if (bucket is null)
        {
            return;
        }

        var used = Math.Round((1 - Math.Clamp(bucket.RemainingFraction, 0, 1)) * 100);
        lines.Add(MetricLine.Progress(label, used, 100, resetsAt: bucket.ResetTime, periodDuration: TimeSpan.FromDays(1)));
    }

    private static void CollectQuotaBuckets(JsonElement element, List<QuotaBucket> buckets)
    {
        if (element.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in element.EnumerateArray())
            {
                CollectQuotaBuckets(item, buckets);
            }
            return;
        }

        if (element.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        if (element.TryGetProperty("remainingFraction", out var remaining) && remaining.TryGetDouble(out var fraction))
        {
            buckets.Add(new QuotaBucket(
                element.StringProp("modelId") ?? element.StringProp("model_id") ?? "unknown",
                fraction,
                DateTimeOffset.TryParse(element.StringProp("resetTime") ?? element.StringProp("reset_time"), out var reset) ? reset : null));
        }

        foreach (var property in element.EnumerateObject())
        {
            CollectQuotaBuckets(property.Value, buckets);
        }
    }

    private sealed record QuotaBucket(string ModelId, double RemainingFraction, DateTimeOffset? ResetTime);
}
