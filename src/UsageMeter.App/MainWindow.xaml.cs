using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Collections.ObjectModel;
using UsageMeter.Core;
using WinRT.Interop;
using Button = Microsoft.UI.Xaml.Controls.Button;

namespace UsageMeter.App;

public sealed partial class MainWindow : Window
{
    private readonly UsageMeterService _service = UsageMeterService.CreateDefault();
    private readonly ObservableCollection<ProviderViewModel> _providers = new();
    private readonly StackPanel _providerList = new() { Spacing = 12 };
    private readonly TextBlock _statusText = new() { Text = "Loading usage...", FontSize = 12 };
    private readonly Button _refreshButton = new() { Content = "Refresh" };
    private ScrollViewer? _scrollViewer;
    private readonly Dictionary<string, FrameworkElement> _providerCards = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Button> _navButtons = new(StringComparer.OrdinalIgnoreCase);
    private string? _selectedProviderId;
    private TrayIconManager? _trayIcon;
    private readonly AppWindow _appWindow;
    private readonly IntPtr _hwnd;
    private bool _isQuitting;
    private bool _isHidingToTray;
    private bool _canHideOnMinimize;

    public MainWindow()
    {
        InitializeComponent();

        _hwnd = WindowNative.GetWindowHandle(this);
        _appWindow = ResolveAppWindow(_hwnd);
        _appWindow.Resize(new Windows.Graphics.SizeInt32(430, 680));
        _appWindow.Closing += OnAppWindowClosing;
        _appWindow.Changed += OnAppWindowChanged;
        InitializeTray();

        BuildLayout();

        Closed += OnClosed;

        _ = RefreshAsync();
    }

    private void InitializeTray()
    {
        _trayIcon ??= new TrayIconManager(ShowAndActivate);
    }

    private void BuildLayout()
    {
        Root.Background = Brush(248, 250, 252);
        Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(50) });
        Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var navRail = CreateNavigationRail();
        Grid.SetColumn(navRail, 0);
        Root.Children.Add(navRail);

        var page = new Grid { Padding = new Thickness(12, 18, 12, 10) };
        page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetColumn(page, 1);
        Root.Children.Add(page);

        _refreshButton.Click += async (_, _) => await RefreshAsync();
        _refreshButton.Foreground = Brush(15, 23, 42);
        var quitButton = new Button { Content = "Quit" };
        quitButton.Foreground = Brush(15, 23, 42);
        quitButton.Click += (_, _) =>
        {
            _isQuitting = true;
            _trayIcon?.Dispose();
            Application.Current.Exit();
        };

        var footer = new Grid { Margin = new Thickness(0, 8, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var footerText = new StackPanel { Spacing = 1 };
        footerText.Children.Add(new TextBlock
        {
            Text = "UsageMeter",
            FontSize = 12,
            Foreground = Brush(71, 85, 105)
        });
        footerText.Children.Add(_statusText);
        footer.Children.Add(footerText);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8
        };
        actions.Children.Add(_refreshButton);
        actions.Children.Add(quitButton);

        Grid.SetColumn(actions, 1);
        footer.Children.Add(actions);

        _scrollViewer = new ScrollViewer
        {
            Content = _providerList,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Padding = new Thickness(0, 0, 4, 0)
        };

        Grid.SetRow(_scrollViewer, 0);
        Grid.SetRow(footer, 1);
        _statusText.Foreground = Brush(71, 85, 105);
        page.Children.Add(_scrollViewer);
        page.Children.Add(footer);
    }

    private FrameworkElement CreateNavigationRail()
    {
        var rail = new Border
        {
            Background = Brush(255, 255, 255),
            BorderBrush = Brush(226, 232, 240),
            BorderThickness = new Thickness(0, 0, 1, 0)
        };

        var grid = new Grid { Padding = new Thickness(0, 12, 0, 12) };
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rail.Child = grid;

        var icons = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        icons.Children.Add(CreateNavItem("codex", "Codex"));
        icons.Children.Add(CreateNavItem("claude", "Claude"));
        icons.Children.Add(CreateNavItem("cursor", "Cursor"));
        icons.Children.Add(CreateNavItem("copilot", "Copilot"));
        icons.Children.Add(CreateNavItem("gemini", "Gemini"));
        icons.Children.Add(CreateNavItem("opencode-go", "OpenCode Go"));
        icons.Children.Add(CreateNavItem("windsurf", "Windsurf"));
        Grid.SetRow(icons, 0);
        grid.Children.Add(icons);
        return rail;
    }

    private Button CreateNavItem(string providerId, string tooltip)
    {
        var button = new Button
        {
            Width = 36,
            Height = 36,
            Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderBrush = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Content = CreateProviderIcon(providerId)
        };
        AutomationProperties.SetName(button, tooltip);
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => ScrollToProvider(providerId);
        _navButtons[providerId] = button;
        return button;
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
            await ResetScrollAsync();
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
        _providerCards.Clear();

        foreach (var provider in _providers)
        {
            var card = CreateCard(provider);
            _providerCards[provider.Id] = card;
            _providerList.Children.Add(card);
        }

        _selectedProviderId ??= _providers.FirstOrDefault()?.Id;
        UpdateNavSelection();
    }

    private async Task ResetScrollAsync()
    {
        await Task.Delay(100);
        _providerList.UpdateLayout();
        _scrollViewer?.UpdateLayout();
        _scrollViewer?.ChangeView(0, 0, null, true);
    }

    private void ScrollToProvider(string providerId)
    {
        _selectedProviderId = providerId;
        UpdateNavSelection();

        if (_scrollViewer is null || !_providerCards.TryGetValue(providerId, out var card))
        {
            return;
        }

        var point = card.TransformToVisual(_providerList).TransformPoint(new Windows.Foundation.Point(0, 0));
        _scrollViewer.ChangeView(0, Math.Max(0, point.Y), null, false);
    }

    private void UpdateNavSelection()
    {
        foreach (var (providerId, button) in _navButtons)
        {
            var selected = string.Equals(providerId, _selectedProviderId, StringComparison.OrdinalIgnoreCase);
            button.Background = selected ? Brush(241, 245, 249) : new SolidColorBrush(Colors.Transparent);
            button.BorderBrush = selected ? Brush(203, 213, 225) : new SolidColorBrush(Colors.Transparent);
        }
    }

    public void ShowAndActivate()
    {
        _appWindow.Show();
        NativeMethods.ShowWindow(_hwnd, NativeMethods.SwRestore);
        _canHideOnMinimize = true;
        Activate();
        NativeMethods.SetForegroundWindow(_hwnd);
    }

    private AppWindow ResolveAppWindow(IntPtr hwnd)
    {
        var windowId = Win32Interop.GetWindowIdFromWindow(hwnd);
        return AppWindow.GetFromWindowId(windowId);
    }

    private void OnAppWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (!sender.IsVisible || sender.Presenter is not OverlappedPresenter presenter)
        {
            return;
        }

        if (presenter.State is OverlappedPresenterState.Restored or OverlappedPresenterState.Maximized)
        {
            _canHideOnMinimize = true;
            return;
        }

        if (_canHideOnMinimize && presenter.State == OverlappedPresenterState.Minimized)
        {
            HideToTray();
        }
    }

    private void HideToTray()
    {
        if (_isQuitting || _trayIcon is null || _isHidingToTray)
        {
            return;
        }

        try
        {
            _isHidingToTray = true;
            _appWindow.Hide();
        }
        finally
        {
            _isHidingToTray = false;
        }
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (!_isQuitting && _trayIcon is not null)
        {
            args.Cancel = true;
            HideToTray();
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _trayIcon?.Dispose();
    }

}
