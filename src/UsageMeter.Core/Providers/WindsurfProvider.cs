using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace UsageMeter.Core.Providers;

public sealed class WindsurfProvider(WindowsPaths paths, HttpClient httpClient, SqliteReader sqlite) : ProviderBase(paths, httpClient)
{
    private const string CloudUrl = "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus";
    private const string CompatVersion = "1.108.2";

    private static readonly (string IdeName, string StateDb)[] Variants =
    [
        ("windsurf", "%APPDATA%/Windsurf/User/globalStorage/state.vscdb"),
        ("windsurf-next", "%APPDATA%/Windsurf - Next/User/globalStorage/state.vscdb")
    ];

    public override string Id => "windsurf";
    public override string DisplayName => "Windsurf";

    protected override async Task<ProviderUsageResult> ProbeCoreAsync(CancellationToken cancellationToken)
    {
        foreach (var variant in Variants)
        {
            var authRaw = sqlite.ReadStateValue(variant.StateDb, "windsurfAuthStatus");
            using var auth = Json.TryParseDocument(authRaw);
            var apiKey = auth?.RootElement.StringProp("apiKey");
            if (string.IsNullOrWhiteSpace(apiKey))
            {
                continue;
            }

            using var request = new HttpRequestMessage(HttpMethod.Post, CloudUrl);
            request.Headers.TryAddWithoutValidation("Connect-Protocol-Version", "1");
            request.Content = JsonContent(new
            {
                metadata = new
                {
                    apiKey,
                    ideName = variant.IdeName,
                    ideVersion = CompatVersion,
                    extensionName = variant.IdeName,
                    extensionVersion = CompatVersion,
                    locale = "en"
                }
            });

            using var doc = await SendJsonAsync(request, cancellationToken).ConfigureAwait(false);
            var planStatus = doc.RootElement.ObjectProp("userStatus")?.ObjectProp("planStatus");
            if (planStatus is null)
            {
                continue;
            }

            var dailyRemaining = planStatus.Value.NumberProp("dailyQuotaRemainingPercent");
            var weeklyRemaining = planStatus.Value.NumberProp("weeklyQuotaRemainingPercent");
            if (dailyRemaining is null || weeklyRemaining is null)
            {
                throw new InvalidOperationException("Windsurf quota data unavailable. Try again later.");
            }

            var lines = new List<MetricLine>
            {
                MetricLine.Progress("Daily quota", ClampPercent(100 - dailyRemaining.Value), 100, resetsAt: UnixSecondsToDateTime(planStatus.Value.NumberProp("dailyQuotaResetAtUnix")), periodDuration: TimeSpan.FromDays(1)),
                MetricLine.Progress("Weekly quota", ClampPercent(100 - weeklyRemaining.Value), 100, resetsAt: UnixSecondsToDateTime(planStatus.Value.NumberProp("weeklyQuotaResetAtUnix")), periodDuration: TimeSpan.FromDays(7))
            };

            var overageMicros = planStatus.Value.NumberProp("overageBalanceMicros");
            if (overageMicros is not null)
            {
                lines.Add(MetricLine.Text("Extra usage balance", "$" + Math.Max(0, overageMicros.Value / 1_000_000).ToString("0.00")));
            }

            var plan = planStatus.Value.ObjectProp("planInfo")?.StringProp("planName") ?? "Unknown";
            return new ProviderUsageResult(Id, DisplayName, plan, lines, DateTimeOffset.Now);
        }

        throw new InvalidOperationException("Start Windsurf or sign in and try again.");
    }
}
