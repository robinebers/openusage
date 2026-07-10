using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using WpfOrientation = System.Windows.Controls.Orientation;
using WpfHorizontalAlignment = System.Windows.HorizontalAlignment;
using WpfBrushes = System.Windows.Media.Brushes;
using WpfFontFamily = System.Windows.Media.FontFamily;
using WpfPoint = System.Windows.Point;

namespace OpenUsageShell;

public partial class FloatingStripWindow : Window
{
    public event Action? OpenFlyoutRequested;
    public event Action? ContextMenuRequested;
    public event Action<double, double>? PositionChanged;

    private WpfPoint? _dragStart;
    private bool _suppressLocationSave;
    private readonly DispatcherTimer _saveTimer;
    private readonly DispatcherTimer _singleClickTimer;
    private readonly WpfFontFamily _mono = new("Cascadia Mono, Consolas, Segoe UI");

    public FloatingStripWindow()
    {
        InitializeComponent();
        _saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        _saveTimer.Tick += (_, _) =>
        {
            _saveTimer.Stop();
            PositionChanged?.Invoke(Left, Top);
        };
        // Delay single-click open so a double-click doesn't open-then-toggle-closed.
        _singleClickTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(280) };
        _singleClickTimer.Tick += (_, _) =>
        {
            _singleClickTimer.Stop();
            OpenFlyoutRequested?.Invoke();
        };
        Body.Content = BuildHint("Connecting…");
        ApplyExplicitSize(EstimateHintSize("Connecting…"));
    }

    public void ApplyPosition(double? left, double? top)
    {
        _suppressLocationSave = true;
        try
        {
            var work = SystemParameters.WorkArea;
            var w = ActualWidth > 0 ? ActualWidth : Width;
            var h = ActualHeight > 0 ? ActualHeight : Height;
            if (double.IsNaN(w) || w <= 0) w = 160;
            if (double.IsNaN(h) || h <= 0) h = 36;

            if (left is double l && top is double t)
            {
                // Clamp into the work area so a saved bottom-edge position isn't discarded.
                Left = Math.Clamp(l, work.Left, Math.Max(work.Left, work.Right - w));
                Top = Math.Clamp(t, work.Top, Math.Max(work.Top, work.Bottom - h));
            }
            else
            {
                Left = work.Left + (work.Width - w) / 2;
                Top = work.Top + 10;
            }
        }
        finally
        {
            _suppressLocationSave = false;
        }
    }

    public void Update(IReadOnlyList<StripSegment> segments)
    {
        var keepLeft = Left;
        var keepTop = Top;

        if (segments.Count == 0)
        {
            Body.Content = BuildHint("Connecting…");
            ApplyExplicitSize(EstimateHintSize("Connecting…"));
        }
        else
        {
            var host = new StackPanel
            {
                Orientation = WpfOrientation.Horizontal,
                VerticalAlignment = VerticalAlignment.Center
            };

            for (var i = 0; i < segments.Count; i++)
            {
                if (i > 0)
                {
                    host.Children.Add(new Border { Width = 11 });
                }

                host.Children.Add(BuildSegment(segments[i]));
            }

            Body.Content = host;
            ApplyExplicitSize(EstimateSegmentsSize(segments));
        }

        // Keep the strip anchored where the user left it after size changes.
        if (!double.IsNaN(keepLeft) && !double.IsNaN(keepTop))
        {
            ApplyPosition(keepLeft, keepTop);
        }
    }

    private void ApplyExplicitSize(System.Windows.Size content)
    {
        // Padding 8,4 + border 1*2 + shadow slack + a little breathing room
        Width = Math.Ceiling(content.Width + 16 + 2 + 16);
        Height = Math.Ceiling(content.Height + 8 + 2 + 10);
        SizeToContent = SizeToContent.Manual;
    }

    private System.Windows.Size EstimateHintSize(string text)
    {
        var width = MeasureText(text, 12, FontWeights.SemiBold);
        return new System.Windows.Size(width, 16);
    }

    private System.Windows.Size EstimateSegmentsSize(IReadOnlyList<StripSegment> segments)
    {
        double width = 0;
        double height = 16;
        for (var i = 0; i < segments.Count; i++)
        {
            if (i > 0)
            {
                width += 11;
            }

            width += 16 + 4; // glyph + gap
            var values = segments[i].Values;
            if (values.Count <= 1)
            {
                var text = values.FirstOrDefault() ?? "—";
                width += MeasureText(text, 12, FontWeights.Bold);
                height = Math.Max(height, 14);
            }
            else
            {
                var top = MeasureText(values[0], 9, FontWeights.SemiBold);
                var bottom = MeasureText(values[1], 9, FontWeights.SemiBold);
                width += Math.Max(top, bottom);
                height = Math.Max(height, 16);
            }
        }

        return new System.Windows.Size(width, height);
    }

    private double MeasureText(string text, double size, FontWeight weight)
    {
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var ft = new FormattedText(
            text,
            CultureInfo.CurrentUICulture,
            System.Windows.FlowDirection.LeftToRight,
            new Typeface(_mono, FontStyles.Normal, weight, FontStretches.Normal),
            size,
            WpfBrushes.White,
            dpi);
        return ft.Width;
    }

    private TextBlock BuildHint(string text)
    {
        var hint = new TextBlock
        {
            Text = text,
            FontFamily = _mono,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(System.Windows.Media.Color.FromArgb(0xCC, 0xFF, 0xFF, 0xFF)),
            VerticalAlignment = VerticalAlignment.Center
        };
        TextOptions.SetTextFormattingMode(hint, TextFormattingMode.Display);
        return hint;
    }

    private FrameworkElement BuildSegment(StripSegment segment)
    {
        var row = new StackPanel
        {
            Orientation = WpfOrientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };

        row.Children.Add(ProviderGlyph.Create(segment.ProviderId, side: 16));
        row.Children.Add(new Border { Width = 4 });

        var metrics = new StackPanel
        {
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = WpfHorizontalAlignment.Right
        };

        if (segment.Values.Count <= 1)
        {
            var single = new TextBlock
            {
                Text = segment.Values.FirstOrDefault() ?? "—",
                FontFamily = _mono,
                FontSize = 12,
                FontWeight = FontWeights.Bold,
                Foreground = WpfBrushes.White,
                LineHeight = 14,
                VerticalAlignment = VerticalAlignment.Center
            };
            TextOptions.SetTextFormattingMode(single, TextFormattingMode.Display);
            metrics.Children.Add(single);
        }
        else
        {
            for (var i = 0; i < segment.Values.Count; i++)
            {
                var line = new TextBlock
                {
                    Text = segment.Values[i],
                    FontFamily = _mono,
                    FontSize = 9,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = WpfBrushes.White,
                    LineHeight = 9,
                    Margin = i == 0 ? new Thickness(0, 0, 0, -2) : new Thickness(0),
                    HorizontalAlignment = WpfHorizontalAlignment.Right
                };
                TextOptions.SetTextFormattingMode(line, TextFormattingMode.Display);
                metrics.Children.Add(line);
            }
        }

        row.Children.Add(metrics);
        return row;
    }

    private void Window_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        // Double-click opens the flyout; cancel any pending single-click.
        if (e.ClickCount >= 2)
        {
            _singleClickTimer.Stop();
            _dragStart = null;
            OpenFlyoutRequested?.Invoke();
            e.Handled = true;
            return;
        }

        _dragStart = e.GetPosition(this);
        try
        {
            DragMove();
        }
        catch
        {
        }
    }

    private void Window_MouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        // Single click (no drag) → open after a short delay (see ctor).
        if (_dragStart is WpfPoint start)
        {
            var end = e.GetPosition(this);
            if (Math.Abs(end.X - start.X) < 4 && Math.Abs(end.Y - start.Y) < 4)
            {
                _singleClickTimer.Stop();
                _singleClickTimer.Start();
            }
        }

        _dragStart = null;
    }

    private void Window_MouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        _singleClickTimer.Stop();
        OpenFlyoutRequested?.Invoke();
        e.Handled = true;
    }

    private void Window_MouseRightButtonUp(object sender, MouseButtonEventArgs e)
    {
        ContextMenuRequested?.Invoke();
    }

    private void Window_LocationChanged(object? sender, EventArgs e)
    {
        if (_suppressLocationSave)
        {
            return;
        }

        _saveTimer.Stop();
        _saveTimer.Start();
    }
}
