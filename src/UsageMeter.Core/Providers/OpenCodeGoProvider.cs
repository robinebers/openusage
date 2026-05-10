using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace UsageMeter.Core.Providers;

public sealed class OpenCodeGoProvider(WindowsPaths paths, HttpClient httpClient, SqliteReader sqlite) : ProviderBase(paths, httpClient)
{
    private const string AuthPath = "~/.local/share/opencode/auth.json";
    private const string DbPath = "~/.local/share/opencode/opencode.db";

    public override string Id => "opencode-go";
    public override string DisplayName => "OpenCode Go";

    protected override Task<ProviderUsageResult> ProbeCoreAsync(CancellationToken cancellationToken)
    {
        var detected = File.Exists(Paths.Expand(AuthPath)) || File.Exists(Paths.Expand(DbPath));
        if (!detected)
        {
            throw new InvalidOperationException("OpenCode Go not detected. Log in with OpenCode Go or use it locally first.");
        }

        var rows = sqlite.Query(DbPath, """
            SELECT
              CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
              CAST(json_extract(data, '$.cost') AS REAL) AS cost
            FROM message
            WHERE json_valid(data)
              AND json_extract(data, '$.providerID') = 'opencode-go'
              AND json_extract(data, '$.role') = 'assistant'
              AND json_type(data, '$.cost') IN ('integer', 'real')
            """);

        if (rows.Count == 0)
        {
            return Task.FromResult(new ProviderUsageResult(Id, DisplayName, "Go", [MetricLine.Badge("Status", "No usage data", "#737373")], DateTimeOffset.Now));
        }

        var now = DateTimeOffset.Now;
        IReadOnlyList<MetricLine> lines =
        [
            MetricLine.Progress("Session", Percent(SumSince(rows, now.AddHours(-5)), 12), 100, resetsAt: now.AddHours(5), periodDuration: TimeSpan.FromHours(5)),
            MetricLine.Progress("Weekly", Percent(SumSince(rows, StartOfWeek(now)), 30), 100, resetsAt: StartOfWeek(now).AddDays(7), periodDuration: TimeSpan.FromDays(7)),
            MetricLine.Progress("Monthly", Percent(SumSince(rows, new DateTimeOffset(now.Year, now.Month, 1, 0, 0, 0, now.Offset)), 60), 100, resetsAt: new DateTimeOffset(now.Year, now.Month, 1, 0, 0, 0, now.Offset).AddMonths(1), periodDuration: TimeSpan.FromDays(30))
        ];

        return Task.FromResult(new ProviderUsageResult(Id, DisplayName, "Go", lines, DateTimeOffset.Now));
    }

    private static double SumSince(IReadOnlyList<Dictionary<string, object?>> rows, DateTimeOffset start)
    {
        var startMs = start.ToUnixTimeMilliseconds();
        return rows.Sum(row =>
        {
            var createdMs = Convert.ToDouble(row.GetValueOrDefault("createdMs") ?? 0);
            return createdMs >= startMs ? Convert.ToDouble(row.GetValueOrDefault("cost") ?? 0) : 0;
        });
    }

    private static double Percent(double used, double limit) => ClampPercent((used / limit) * 100);
    private static DateTimeOffset StartOfWeek(DateTimeOffset value) => value.Date.AddDays(-(((int)value.DayOfWeek + 6) % 7));
}
