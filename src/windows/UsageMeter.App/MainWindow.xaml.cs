using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Collections.ObjectModel;
using UsageMeter.Core;
using WinRT.Interop;
using Button = Microsoft.UI.Xaml.Controls.Button;
using Color = Windows.UI.Color;
using FontFamily = Microsoft.UI.Xaml.Media.FontFamily;
using ProgressBar = Microsoft.UI.Xaml.Controls.ProgressBar;

namespace UsageMeter.App;

public sealed partial class MainWindow : Window
{
    private readonly UsageMeterService _service = UsageMeterService.CreateDefault();
    private readonly ObservableCollection<ProviderViewModel> _providers = new();
    private readonly StackPanel _providerList = new() { Spacing = 12 };
    private readonly TextBlock _statusText = new() { Text = "Loading usage...", Opacity = 0.72 };
    private readonly Button _refreshButton = new() { Content = "Refresh" };
    private TrayIconManager? _trayIcon;
    private readonly AppWindow _appWindow;
    private bool _isQuitting;

    public MainWindow()
    {
        InitializeComponent();

        _appWindow = ResolveAppWindow();
        _appWindow.Resize(new Windows.Graphics.SizeInt32(430, 680));
        _appWindow.Closing += OnAppWindowClosing;

        BuildLayout();

        Closed += (_, _) => _trayIcon?.Dispose();

        _ = RefreshAsync();
    }

    public void InitializeTray()
    {
        _trayIcon ??= new TrayIconManager(ShowWindow);
    }

    private void BuildLayout()
    {
        Root.Background = new SolidColorBrush(Color.FromArgb(255, 245, 246, 248));
        Root.Padding = new Thickness(18);
        Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new Grid { Margin = new Thickness(0, 0, 0, 14) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var title = new StackPanel { Spacing = 2 };
        title.Children.Add(new TextBlock
        {
            Text = "Usage Meter",
            FontSize = 24,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold
        });
        title.Children.Add(new TextBlock
        {
            Text = "AI tool usage across local accounts",
            Foreground = new SolidColorBrush(Color.FromArgb(255, 83, 91, 107))
        });
        header.Children.Add(title);

        _refreshButton.Click += async (_, _) => await RefreshAsync();
        var quitButton = new Button { Content = "Quit" };
        quitButton.Click += (_, _) =>
        {
            _isQuitting = true;
            _trayIcon?.Dispose();
            Application.Current.Exit();
        };

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8
        };
        actions.Children.Add(_refreshButton);
        actions.Children.Add(quitButton);

        Grid.SetColumn(actions, 1);
        header.Children.Add(actions);

        var scroll = new ScrollViewer
        {
            Content = _providerList,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };

        Grid.SetRow(header, 0);
        Grid.SetRow(scroll, 1);
        Grid.SetRow(_statusText, 2);
        Root.Children.Add(header);
        Root.Children.Add(scroll);
        Root.Children.Add(_statusText);
    }

    private async Task RefreshAsync()
    {
        _refreshButton.IsEnabled = false;
        _statusText.Text = "Refreshing...";

        try
        {
            var snapshot = await _service.RefreshAsync();
            _providers.Clear();
            foreach (var provider in snapshot.Providers)
            {
                _providers.Add(new ProviderViewModel(provider));
            }

            RenderProviders();
            _statusText.Text = $"Updated {snapshot.UpdatedAt.LocalDateTime:g}";
        }
        catch (Exception ex)
        {
            _statusText.Text = $"Refresh failed: {ex.Message}";
        }
        finally
        {
            _refreshButton.IsEnabled = true;
        }
    }

    private void RenderProviders()
    {
        _providerList.Children.Clear();

        foreach (var provider in _providers)
        {
            var card = CreateCard(provider);
            _providerList.Children.Add(card);
        }
    }

    private UIElement CreateCard(ProviderViewModel provider)
    {
        var border = new Border
        {
            Background = new SolidColorBrush(Colors.White),
            BorderBrush = new SolidColorBrush(Color.FromArgb(255, 220, 224, 231)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(14)
        };

        var panel = new StackPanel { Spacing = 10 };
        border.Child = panel;

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        header.Children.Add(new TextBlock
        {
            Text = provider.Name,
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold
        });

        var status = new Border
        {
            Background = new SolidColorBrush(provider.IsAvailable ? Color.FromArgb(255, 225, 244, 232) : Color.FromArgb(255, 245, 230, 232)),
            CornerRadius = new CornerRadius(999),
            Padding = new Thickness(10, 4, 10, 4),
            Child = new TextBlock
            {
                Text = provider.Status,
                Foreground = new SolidColorBrush(provider.IsAvailable ? Color.FromArgb(255, 21, 112, 57) : Color.FromArgb(255, 176, 58, 72)),
                FontSize = 12
            }
        };
        Grid.SetColumn(status, 1);
        header.Children.Add(status);
        panel.Children.Add(header);

        if (!string.IsNullOrWhiteSpace(provider.Message))
        {
            panel.Children.Add(new TextBlock
            {
                Text = provider.Message,
                Foreground = new SolidColorBrush(Color.FromArgb(255, 83, 91, 107)),
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
        var row = new StackPanel { Spacing = 5 };

        var textRow = new Grid();
        textRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        textRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        textRow.Children.Add(new TextBlock { Text = line.Label, TextWrapping = TextWrapping.Wrap });

        if (!string.IsNullOrWhiteSpace(line.Value))
        {
            var value = new TextBlock
            {
                Text = line.Value,
                FontFamily = new FontFamily("Consolas"),
                Foreground = new SolidColorBrush(Color.FromArgb(255, 38, 45, 56))
            };
            Grid.SetColumn(value, 1);
            textRow.Children.Add(value);
        }

        row.Children.Add(textRow);

        if (line.Progress.HasValue)
        {
            row.Children.Add(new ProgressBar
            {
                Minimum = 0,
                Maximum = 100,
                Value = line.Progress.Value,
                Height = 6
            });
        }

        return row;
    }

    private void ShowWindow()
    {
        _appWindow.Show();
        Activate();
        NativeMethods.SetForegroundWindow(WindowNative.GetWindowHandle(this));
    }

    private AppWindow ResolveAppWindow()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(hwnd);
        return AppWindow.GetFromWindowId(windowId);
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (!_isQuitting && _trayIcon is not null)
        {
            args.Cancel = true;
            sender.Hide();
        }
    }
}
