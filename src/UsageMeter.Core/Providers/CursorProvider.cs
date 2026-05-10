using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace UsageMeter.Core.Providers;

public sealed class CursorProvider(WindowsPaths paths, HttpClient httpClient, SqliteReader sqlite) : ProviderBase(paths, httpClient)
{
    private const string StateDb = "%APPDATA%/Cursor/User/globalStorage/state.vscdb";
    private const string UsageUrl = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage";
    private const string PlanUrl = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo";

    public override string Id => "cursor";
    public override string DisplayName => "Cursor";

    protected override async Task<ProviderUsageResult> ProbeCoreAsync(CancellationToken cancellationToken)
    {
        var token = sqlite.ReadStateValue(StateDb, "cursorAuth/accessToken");
        if (string.IsNullOrWhiteSpace(token))
        {
            throw new InvalidOperationException("Not logged in. Sign in via Cursor and try again.");
        }

        using var usageRequest = ConnectPost(UsageUrl, token);
        using var usageDoc = await SendJsonAsync(usageRequest, cancellationToken).ConfigureAwait(false);
        var plan = await ReadPlanAsync(token, cancellationToken).ConfigureAwait(false);
        var planUsage = usageDoc.RootElement.ObjectProp("planUsage");
        var lines = new List<MetricLine>();

        AddPercent(lines, "Total usage", planUsage?.NumberProp("totalPercentUsed"));
        AddPercent(lines, "Auto usage", planUsage?.NumberProp("autoPercentUsed"));
        AddPercent(lines, "API usage", planUsage?.NumberProp("apiPercentUsed"));

        if (lines.Count == 0)
        {
            lines.Add(MetricLine.Badge("Status", "No usage data", "#737373"));
        }

        return new ProviderUsageResult(Id, DisplayName, plan, lines, DateTimeOffset.Now);
    }

    private async Task<string?> ReadPlanAsync(string token, CancellationToken cancellationToken)
    {
        try
        {
            using var planRequest = ConnectPost(PlanUrl, token);
            using var planDoc = await SendJsonAsync(planRequest, cancellationToken).ConfigureAwait(false);
            return planDoc.RootElement.ObjectProp("planInfo")?.StringProp("planName");
        }
        catch
        {
            return null;
        }
    }

    private static HttpRequestMessage ConnectPost(string url, string token)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Authorization = Bearer(token);
        request.Headers.TryAddWithoutValidation("Connect-Protocol-Version", "1");
        request.Content = JsonContent(new { });
        return request;
    }

    private static void AddPercent(List<MetricLine> lines, string label, double? value)
    {
        if (value is not null)
        {
            lines.Add(MetricLine.Progress(label, ClampPercent(value.Value), 100));
        }
    }
}
