using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace UsageMeter.Core.Providers;

public abstract class ProviderBase(WindowsPaths paths, HttpClient httpClient) : IUsageProvider
{
    protected WindowsPaths Paths { get; } = paths;
    protected HttpClient Http { get; } = httpClient;

    public abstract string Id { get; }
    public abstract string DisplayName { get; }

    public async Task<ProviderUsageResult> ProbeAsync(CancellationToken cancellationToken)
    {
        try
        {
            var result = await ProbeCoreAsync(cancellationToken).ConfigureAwait(false);
            return result with { LastUpdatedAt = DateTimeOffset.Now };
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            return ProviderUsageResult.Failure(Id, DisplayName, ex.Message);
        }
    }

    protected abstract Task<ProviderUsageResult> ProbeCoreAsync(CancellationToken cancellationToken);

    protected string ReadRequiredFile(params string[] candidates)
    {
        foreach (var candidate in candidates)
        {
            var path = Paths.Expand(candidate);
            if (File.Exists(path))
            {
                return File.ReadAllText(path);
            }
        }

        throw new InvalidOperationException($"Not logged in. No auth file found for {DisplayName}.");
    }

    protected async Task<JsonDocument> SendJsonAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        using var response = await Http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Usage request failed (HTTP {(int)response.StatusCode}). Try again later.");
        }

        return JsonDocument.Parse(body);
    }

    protected static StringContent JsonContent(object value) =>
        new(JsonSerializer.Serialize(value, Json.WebOptions), Encoding.UTF8, "application/json");

    protected static AuthenticationHeaderValue Bearer(string token) => new("Bearer", token.Trim());
    protected static DateTimeOffset? UnixSecondsToDateTime(double? seconds) => seconds is null ? null : DateTimeOffset.FromUnixTimeSeconds((long)seconds.Value);
    protected static double ClampPercent(double value) => Math.Max(0, Math.Min(100, value));
}
