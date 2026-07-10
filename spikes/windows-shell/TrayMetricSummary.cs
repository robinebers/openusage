using System.Globalization;
using System.Text.RegularExpressions;

namespace OpenUsageShell;

/// <summary>
/// Picks a single headline metric for the Windows 11-style taskbar pill / tray icon.
/// Prefers the highest progress % among providers that have credentials.
/// </summary>
public sealed class TrayMetricSummary
{
    public string PrimaryText { get; init; } = "—";
    public string SecondaryText { get; init; } = "OpenUsage";
    public double? Percent { get; init; }
    public string Tooltip { get; init; } = "OpenUsage";

    public static TrayMetricSummary FromProviders(IReadOnlyList<SidecarProvider> providers)
    {
        var withCreds = providers.Where(p => p.CredentialsFound).ToList();
        if (withCreds.Count == 0)
        {
            return new TrayMetricSummary
            {
                PrimaryText = "—",
                SecondaryText = "No accounts",
                Tooltip = "OpenUsage — no credentials found"
            };
        }

        var best = withCreds
            .Select(p => (Provider: p, Hit: FindBestProgress(p)))
            .Where(x => x.Hit is not null)
            .OrderByDescending(x => x.Hit!.Percent)
            .FirstOrDefault();

        if (best.Hit is null)
        {
            var names = string.Join(", ", withCreds.Select(p => p.DisplayName));
            return new TrayMetricSummary
            {
                PrimaryText = withCreds.Count.ToString(CultureInfo.InvariantCulture),
                SecondaryText = "Providers",
                Tooltip = $"OpenUsage — {names}"
            };
        }

        var used = best.Hit.Percent;
        // Match macOS default meter style "Left" (remaining) for the visible number.
        var left = Math.Clamp(100 - used, 0, 100);
        var percentText = $"{left:0}%";
        var tooltipLines = withCreds.Select(p =>
        {
            var hit = FindBestProgress(p);
            if (hit is null)
            {
                return $"{p.DisplayName}: ok";
            }

            var remaining = Math.Clamp(100 - hit.Percent, 0, 100);
            return $"{p.DisplayName}: {remaining:0}% left ({hit.Label})";
        });

        return new TrayMetricSummary
        {
            PrimaryText = percentText,
            SecondaryText = best.Provider.DisplayName,
            // Color bands key off share *used* (same as macOS meter colors).
            Percent = used,
            Tooltip = "OpenUsage\n" + string.Join("\n", tooltipLines)
        };
    }

    private static ProgressHit? FindBestProgress(SidecarProvider provider)
    {
        ProgressHit? best = null;
        foreach (var line in provider.MetricLines)
        {
            if (!string.Equals(line.Kind, "progress", StringComparison.OrdinalIgnoreCase)
                && !line.Display.Contains('%', StringComparison.Ordinal))
            {
                continue;
            }

            var match = Regex.Match(line.Display, @"(\d+(?:\.\d+)?)\s*%");
            if (!match.Success)
            {
                continue;
            }

            if (!double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var pct))
            {
                continue;
            }

            if (best is null || pct > best.Percent)
            {
                best = new ProgressHit(pct, string.IsNullOrWhiteSpace(line.Label) ? provider.DisplayName : line.Label);
            }
        }

        return best;
    }

    private sealed record ProgressHit(double Percent, string Label);
}
