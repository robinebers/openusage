using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using WpfBrushes = System.Windows.Media.Brushes;

namespace OpenUsageShell;

public partial class FlyoutWindow : Window
{
    private bool _suppressLaunchAtLoginEvent;
    private bool _hasUpdateBanner;

    /// <summary>Raised after content/layout changes so the host can re-anchor above the taskbar.</summary>
    public event Action? LayoutSettled;

    public FlyoutWindow()
    {
        InitializeComponent();
        SizeChanged += (_, _) =>
        {
            if (IsVisible)
            {
                LayoutSettled?.Invoke();
            }
        };
    }

    public void SetRefreshing(bool refreshing)
    {
        RefreshingText.Visibility = refreshing ? Visibility.Visible : Visibility.Collapsed;
        RequestLayoutSettle();
    }

    public void SetProviders(IReadOnlyList<SidecarProvider> providers)
    {
        ErrorText.Visibility = Visibility.Collapsed;
        if (!_hasUpdateBanner)
        {
            BannerText.Visibility = Visibility.Collapsed;
        }

        ProviderList.ItemsSource = ProviderSectionViewModel.Build(providers);
        RequestLayoutSettle();
    }

    private void RequestLayoutSettle()
    {
        Dispatcher.BeginInvoke(() =>
        {
            ApplyScrollCap();
            SizeToContent = SizeToContent.Height;
            UpdateLayout();
            LayoutSettled?.Invoke();
        }, System.Windows.Threading.DispatcherPriority.Loaded);
    }

    private void Window_SourceInitialized(object? sender, EventArgs e) => ApplyScrollCap();

    private void ApplyScrollCap()
    {
        var work = SystemParameters.WorkArea;
        // Leave room for the footer + shadow; only scroll when content exceeds ~85% of the screen.
        var max = Math.Max(280, work.Height * 0.85 - 56);
        ContentScroll.MaxHeight = max;
    }

    public void SetError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }

    public void SetBanner(string message)
    {
        _hasUpdateBanner = false;
        BannerText.Inlines.Clear();
        BannerText.Text = message;
        BannerText.Visibility = Visibility.Visible;
    }

    public void SetUpdateBanner(string version, string downloadUrl)
    {
        _hasUpdateBanner = true;
        BannerText.Inlines.Clear();

        BannerText.Inlines.Add(new Run("Update available: "));
        BannerText.Inlines.Add(new Run(version) { FontWeight = FontWeights.SemiBold });
        BannerText.Inlines.Add(new Run(" — "));

        var link = new Hyperlink(new Run("Download"))
        {
            NavigateUri = new Uri(downloadUrl),
            Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(0x7A, 0xB8, 0xFF))
        };
        link.RequestNavigate += (_, e) =>
        {
            UpdateChecker.OpenDownloadUrl(e.Uri.AbsoluteUri);
            e.Handled = true;
        };
        BannerText.Inlines.Add(link);
        BannerText.Visibility = Visibility.Visible;
    }

    public void SetLaunchAtLogin(bool enabled)
    {
        _suppressLaunchAtLoginEvent = true;
        LaunchAtLoginCheck.IsChecked = enabled;
        _suppressLaunchAtLoginEvent = false;
    }

    private void Window_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Hide();
        }
    }

    private void Window_Deactivated(object? sender, EventArgs e)
    {
        Hide();
    }

    private void Refresh_Click(object sender, RoutedEventArgs e)
    {
        TrayActions.RequestRefresh();
    }

    private void LaunchAtLogin_Changed(object sender, RoutedEventArgs e)
    {
        if (_suppressLaunchAtLoginEvent)
        {
            return;
        }

        TrayActions.RequestLaunchAtLoginChange(LaunchAtLoginCheck.IsChecked == true);
    }
}

internal sealed class ProviderSectionViewModel
{
    private static readonly string[] PreferredOrder =
    [
        "claude", "codex", "cursor", "antigravity", "copilot", "devin", "grok", "openrouter", "zai"
    ];

    public required string Title { get; init; }
    public string? Plan { get; init; }
    public Visibility PlanVisibility => string.IsNullOrWhiteSpace(Plan) ? Visibility.Collapsed : Visibility.Visible;
    public string? StatusLine { get; init; }
    public Visibility StatusVisibility => string.IsNullOrWhiteSpace(StatusLine) ? Visibility.Collapsed : Visibility.Visible;
    public double CardOpacity { get; init; } = 1.0;
    public required FrameworkElement Glyph { get; init; }
    public required IReadOnlyList<MetricRowViewModel> Rows { get; init; }

    public static IReadOnlyList<ProviderSectionViewModel> Build(IReadOnlyList<SidecarProvider> providers)
    {
        var byId = providers.ToDictionary(p => p.Id, StringComparer.OrdinalIgnoreCase);
        var ordered = new List<SidecarProvider>();

        foreach (var id in PreferredOrder)
        {
            if (byId.Remove(id, out var p))
            {
                ordered.Add(p);
            }
        }

        ordered.AddRange(byId.Values.OrderBy(p => p.DisplayName, StringComparer.OrdinalIgnoreCase));

        return ordered
            .OrderByDescending(p => p.CredentialsFound)
            .ThenBy(p =>
            {
                var idx = Array.FindIndex(PreferredOrder, id => id.Equals(p.Id, StringComparison.OrdinalIgnoreCase));
                return idx >= 0 ? idx : 100;
            })
            .ThenBy(p => p.DisplayName, StringComparer.OrdinalIgnoreCase)
            .Select(From)
            .ToList();
    }

    private static ProviderSectionViewModel From(SidecarProvider provider)
    {
        string? status = provider.Status switch
        {
            "no_credentials" => "No credentials found",
            "error" => provider.Error,
            "pending" => "Refreshing…",
            _ => string.IsNullOrWhiteSpace(provider.Error) ? null : provider.Error
        };

        var rows = provider.MetricLines
            .Select(MetricRowViewModel.From)
            .Where(r => r is not null)
            .Cast<MetricRowViewModel>()
            .ToList();

        if (rows.Count == 0 && provider.CredentialsFound && provider.Status == "ok")
        {
            rows.Add(MetricRowViewModel.Text("Usage", "No usage data"));
        }

        var signedIn = provider.CredentialsFound && provider.Status is not "no_credentials";
        return new ProviderSectionViewModel
        {
            Title = provider.DisplayName,
            Plan = provider.Plan,
            StatusLine = status ?? (signedIn ? null : "Not signed in"),
            CardOpacity = signedIn ? 1.0 : 0.45,
            Glyph = ProviderGlyph.Create(provider.Id, side: 18),
            Rows = rows
        };
    }
}

internal sealed class MetricRowViewModel
{
    public required string Label { get; init; }
    public required string PrimaryText { get; init; }
    public string SecondaryText { get; init; } = "";
    public string PaceText { get; init; } = "";
    public double LeftPercent { get; init; }
    public double LeftFraction => LeftPercent / 100.0;
    public System.Windows.Media.Brush BarBrush { get; init; } = WpfBrushes.DodgerBlue;
    public System.Windows.Media.Brush ValueBrush { get; init; } =
        new SolidColorBrush(System.Windows.Media.Color.FromRgb(0xAC, 0xAB, 0xB0));
    public Visibility ProgressVisibility { get; init; } = Visibility.Collapsed;
    public Visibility TextVisibility { get; init; } = Visibility.Visible;

    public static MetricRowViewModel Text(string label, string value) => new()
    {
        Label = label,
        PrimaryText = value,
        TextVisibility = Visibility.Visible,
        ProgressVisibility = Visibility.Collapsed
    };

    public static MetricRowViewModel? From(SidecarMetricLine line)
    {
        if (string.Equals(line.Kind, "chart", StringComparison.OrdinalIgnoreCase))
        {
            // Sparkline parity is later — skip empty chart stubs that only add scroll height.
            return null;
        }

        if (string.Equals(line.Kind, "progress", StringComparison.OrdinalIgnoreCase)
            || line.Display.Contains('%', StringComparison.Ordinal))
        {
            var used = ExtractPercent(line.Display);
            if (used is double u)
            {
                // macOS default meter style = Left (remaining).
                var left = Math.Clamp(100 - u, 0, 100);
                var brush = BrushForUsed(u);
                return new MetricRowViewModel
                {
                    Label = line.Label,
                    PrimaryText = $"{left:0}% left",
                    SecondaryText = "",
                    PaceText = "",
                    LeftPercent = left,
                    BarBrush = brush,
                    ProgressVisibility = Visibility.Visible,
                    TextVisibility = Visibility.Collapsed
                };
            }
        }

        var value = line.Display;
        var prefix = line.Label + ": ";
        if (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
            value = value[prefix.Length..];
        }

        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        // Spend rows get a soft green so the panel isn't monochrome like a log dump.
        if (value.Contains('$', StringComparison.Ordinal))
        {
            return new MetricRowViewModel
            {
                Label = line.Label,
                PrimaryText = value,
                TextVisibility = Visibility.Visible,
                ProgressVisibility = Visibility.Collapsed,
                ValueBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(0x30, 0xD1, 0x58))
            };
        }

        return Text(line.Label, value);
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

    private static System.Windows.Media.Brush BrushForUsed(double usedPct) => usedPct switch
    {
        >= 90 => new SolidColorBrush(System.Windows.Media.Color.FromRgb(0xFF, 0x45, 0x3A)),
        >= 80 => new SolidColorBrush(System.Windows.Media.Color.FromRgb(0xFF, 0x9F, 0x0A)),
        _ => new SolidColorBrush(System.Windows.Media.Color.FromRgb(0x0A, 0x84, 0xFF))
    };
}

internal static class TrayActions
{
    private static Action? _refresh;
    private static Action<bool>? _launchAtLoginChanged;

    public static void RegisterRefresh(Action refresh) => _refresh = refresh;

    public static void RegisterLaunchAtLoginChanged(Action<bool> handler) => _launchAtLoginChanged = handler;

    public static void RequestRefresh() => _refresh?.Invoke();

    public static void RequestLaunchAtLoginChange(bool enabled) => _launchAtLoginChanged?.Invoke(enabled);
}
