using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using IOPath = System.IO.Path;
using WpfBrushes = System.Windows.Media.Brushes;
using WpfPath = System.Windows.Shapes.Path;

namespace OpenUsageShell;

/// <summary>
/// Renders provider brand marks from the same SVG assets as macOS (white template glyphs).
/// </summary>
internal static class ProviderGlyph
{
    private static readonly Dictionary<string, string> PathCache = new(StringComparer.OrdinalIgnoreCase);

    public static FrameworkElement Create(string providerId, double side = 16)
    {
        var pathData = GetPathData(providerId);
        if (pathData is null)
        {
            return new Ellipse
            {
                Width = side - 1,
                Height = side - 1,
                Fill = WpfBrushes.White,
                VerticalAlignment = VerticalAlignment.Center
            };
        }

        // 4% inset mirrors ProviderIconShape(inset: 0.04) on macOS so marks fill the box evenly.
        var inset = side * 0.04;
        var path = new WpfPath
        {
            Data = Geometry.Parse(pathData),
            Fill = WpfBrushes.White,
            Stretch = Stretch.Uniform,
            SnapsToDevicePixels = true
        };

        return new Viewbox
        {
            Width = side - inset * 2,
            Height = side - inset * 2,
            Margin = new Thickness(inset),
            Stretch = Stretch.Uniform,
            Child = path,
            VerticalAlignment = VerticalAlignment.Center,
            SnapsToDevicePixels = true,
            UseLayoutRounding = true
        };
    }

    private static string? GetPathData(string providerId)
    {
        if (PathCache.TryGetValue(providerId, out var cached))
        {
            return cached;
        }

        var file = IOPath.Combine(AppContext.BaseDirectory, "Assets", "Providers", $"{providerId}.svg");
        if (!File.Exists(file))
        {
            return null;
        }

        var svg = File.ReadAllText(file);
        var match = Regex.Match(svg, """d="([^"]+)""" , RegexOptions.CultureInvariant);
        if (!match.Success)
        {
            return null;
        }

        PathCache[providerId] = match.Groups[1].Value;
        return PathCache[providerId];
    }
}

/// <summary>One provider segment in the floating strip (icon + 1–2 stacked values).</summary>
public sealed class StripSegment
{
    public required string ProviderId { get; init; }
    public required string DisplayName { get; init; }
    public required IReadOnlyList<string> Values { get; init; }
}

/// <summary>
/// Builds macOS-menu-bar-equivalent strip segments from sidecar snapshots.
/// Prefers the same default pins: Claude/Codex session+weekly, Cursor auto+api.
/// </summary>
internal static class StripContentBuilder
{
    private static readonly string[] PreferredLabels =
    [
        "session", "weekly", "auto", "api", "total", "premium", "credits", "daily"
    ];

    public static IReadOnlyList<StripSegment> Build(IReadOnlyList<SidecarProvider> providers)
    {
        var order = new[] { "claude", "codex", "cursor", "copilot", "grok", "openrouter", "zai", "devin", "antigravity" };
        var byId = providers.Where(p => p.CredentialsFound && p.Status is "ok" or "pending")
            .ToDictionary(p => p.Id, StringComparer.OrdinalIgnoreCase);

        var segments = new List<StripSegment>();
        foreach (var id in order)
        {
            if (!byId.TryGetValue(id, out var provider))
            {
                continue;
            }

            var values = PickValues(provider);
            if (values.Count == 0)
            {
                continue;
            }

            segments.Add(new StripSegment
            {
                ProviderId = provider.Id,
                DisplayName = provider.DisplayName,
                Values = values
            });
        }

        // Any remaining credentialed providers not in the preferred order.
        foreach (var provider in providers.Where(p => p.CredentialsFound && p.Status == "ok"))
        {
            if (segments.Any(s => s.ProviderId.Equals(provider.Id, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            var values = PickValues(provider);
            if (values.Count == 0)
            {
                continue;
            }

            segments.Add(new StripSegment
            {
                ProviderId = provider.Id,
                DisplayName = provider.DisplayName,
                Values = values
            });
        }

        return segments;
    }

    private static List<string> PickValues(SidecarProvider provider)
    {
        var scored = new List<(int Score, int Index, string Value)>();
        for (var i = 0; i < provider.MetricLines.Count; i++)
        {
            var line = provider.MetricLines[i];
            var pct = ExtractPercent(line.Display);
            if (pct is null)
            {
                continue;
            }

            var label = line.Label.Trim().ToLowerInvariant();
            var score = 100;
            for (var p = 0; p < PreferredLabels.Length; p++)
            {
                if (label.Contains(PreferredLabels[p], StringComparison.Ordinal))
                {
                    score = p;
                    break;
                }
            }

            // Prefer progress-kind rows.
            if (!string.Equals(line.Kind, "progress", StringComparison.OrdinalIgnoreCase))
            {
                score += 50;
            }

            scored.Add((score, i, FormatPercent(pct.Value)));
        }

        return scored
            .OrderBy(s => s.Score)
            .ThenBy(s => s.Index)
            .Select(s => s.Value)
            .Take(2)
            .ToList();
    }

    private static double? ExtractPercent(string display)
    {
        var match = Regex.Match(display, @"(\d+(?:\.\d+)?)\s*%");
        if (!match.Success)
        {
            return null;
        }

        return double.TryParse(match.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var pct)
            ? pct
            : null;
    }

    /// <summary>
    /// macOS menu bar defaults to meter style "Left" (remaining). The sidecar encodes raw <c>used</c>
    /// for percent meters (0…100 with limit 100), so invert for strip parity.
    /// </summary>
    private static string FormatPercent(double usedPct) =>
        $"{Math.Clamp(100 - usedPct, 0, 100):0}%";
}
