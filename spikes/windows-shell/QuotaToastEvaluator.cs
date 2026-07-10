using System.Text.RegularExpressions;

namespace OpenUsageShell;

/// <summary>
/// Stub quota notification evaluator: fires a one-shot toast when a progress metric is ≥90%.
/// </summary>
internal static partial class QuotaToastEvaluator
{
    [GeneratedRegex(@"(\d+)\s*%")]
    private static partial Regex PercentRegex();

    public sealed record QuotaAlert(string ProviderId, string ProviderName, string Label, int Percent);

    public static IReadOnlyList<QuotaAlert> FindAlerts(IReadOnlyList<SidecarProvider> providers, int thresholdPercent = 90)
    {
        var alerts = new List<QuotaAlert>();
        foreach (var provider in providers)
        {
            if (provider.Status != "ok")
            {
                continue;
            }

            foreach (var line in provider.MetricLines)
            {
                if (!string.Equals(line.Kind, "progress", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var percent = ParsePercent(line.Display);
                if (percent is null || percent.Value < thresholdPercent)
                {
                    continue;
                }

                alerts.Add(new QuotaAlert(provider.Id, provider.DisplayName, line.Label, percent.Value));
            }
        }

        return alerts;
    }

    public static string DedupeKey(QuotaAlert alert) => $"{alert.ProviderId}:{alert.Label}";

    private static int? ParsePercent(string display)
    {
        var match = PercentRegex().Match(display);
        if (!match.Success || !int.TryParse(match.Groups[1].Value, out var value))
        {
            return null;
        }

        return value;
    }
}
