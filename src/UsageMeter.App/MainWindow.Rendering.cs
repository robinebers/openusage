using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using UsageMeter.Core;
using Color = Windows.UI.Color;
using ProgressBar = Microsoft.UI.Xaml.Controls.ProgressBar;

namespace UsageMeter.App;

public sealed partial class MainWindow
{
    private FrameworkElement CreateCard(ProviderViewModel provider)
    {
        var border = new Border
        {
            Background = new SolidColorBrush(Colors.White),
            BorderBrush = Brush(226, 232, 240),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(14, 14, 14, 12)
        };

        var panel = new StackPanel { Spacing = 12 };
        border.Child = panel;

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        header.Children.Add(new TextBlock
        {
            Text = provider.Name,
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Brush(2, 6, 23)
        });

        var badgeText = provider.IsAvailable
            ? string.IsNullOrWhiteSpace(provider.Plan) ? "Ready" : provider.Plan
            : "Needs login";
        var status = new Border
        {
            Background = provider.IsAvailable ? Brush(255, 255, 255) : Brush(254, 242, 242),
            BorderBrush = provider.IsAvailable ? Brush(15, 23, 42) : Brush(239, 68, 68),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(7),
            Padding = new Thickness(8, 3, 8, 4),
            Child = new TextBlock
            {
                Text = badgeText,
                Foreground = provider.IsAvailable ? Brush(2, 6, 23) : Brush(185, 28, 28),
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold
            }
        };
        Grid.SetColumn(status, 1);
        header.Children.Add(status);
        panel.Children.Add(header);

        if (!string.IsNullOrWhiteSpace(provider.Error))
        {
            panel.Children.Add(new TextBlock
            {
                Text = provider.Error,
                Foreground = Brush(185, 28, 28),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap
            });
        }

        foreach (var line in provider.Lines)
        {
            panel.Children.Add(CreateMetricLine(line));
        }

        return border;
    }

    private UIElement CreateMetricLine(MetricLineViewModel line)
    {
        var row = new StackPanel { Spacing = 6 };

        var labelRow = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center
        };

        labelRow.Children.Add(new Border
        {
            Width = 8,
            Height = 8,
            CornerRadius = new CornerRadius(999),
            Background = ProgressAccent(line.Progress)
        });
        labelRow.Children.Add(new TextBlock
        {
            Text = line.Label,
            Foreground = Brush(2, 6, 23),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap
        });

        row.Children.Add(labelRow);

        if (line.Progress.HasValue)
        {
            row.Children.Add(new ProgressBar
            {
                Minimum = 0,
                Maximum = 100,
                Value = line.Progress.Value,
                Height = 12,
                CornerRadius = new CornerRadius(4),
                Foreground = Brush(15, 23, 42),
                Background = Brush(241, 245, 249)
            });

            var meta = new Grid();
            meta.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            meta.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            meta.Children.Add(new TextBlock
            {
                Text = line.LeftText,
                FontSize = 12,
                Foreground = Brush(71, 85, 105)
            });
            if (!string.IsNullOrWhiteSpace(line.ResetText))
            {
                var reset = new TextBlock
                {
                    Text = line.ResetText,
                    FontSize = 12,
                    Foreground = Brush(71, 85, 105),
                    HorizontalAlignment = HorizontalAlignment.Right
                };
                Grid.SetColumn(reset, 1);
                meta.Children.Add(reset);
            }

            row.Children.Add(meta);
        }
        else if (!string.IsNullOrWhiteSpace(line.Value))
        {
            row.Children.Add(new TextBlock
            {
                Text = line.Value,
                Foreground = line.Kind == MetricLineKind.Badge ? Brush(185, 28, 28) : Brush(71, 85, 105),
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap
            });
        }

        return row;
    }

    private static SolidColorBrush Brush(byte red, byte green, byte blue) =>
        new(Color.FromArgb(255, red, green, blue));

    private static SolidColorBrush ProgressAccent(double? progress)
    {
        if (progress is >= 90)
        {
            return Brush(239, 68, 68);
        }

        if (progress is >= 70)
        {
            return Brush(234, 179, 8);
        }

        return Brush(16, 185, 129);
    }
}
