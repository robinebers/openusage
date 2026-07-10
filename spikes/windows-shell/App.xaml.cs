using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using WpfApplication = System.Windows.Application;
using WinForms = System.Windows.Forms;

namespace OpenUsageShell;

public partial class App : WpfApplication
{
    private SingleInstanceManager? _singleInstance;
    private TrayController? _tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        ShellPaths.EnsureDirectories();
        ShellLogger.Instance.Info("lifecycle", "OpenUsage shell starting");

        RegisterExceptionHandlers();
        AppIdentity.EnsureRegistered();
        ToastService.Initialize();

        if (!SingleInstanceManager.TryBecomePrimary(out _singleInstance))
        {
            ShellLogger.Instance.Info("lifecycle", "Secondary instance exiting after signal");
            Shutdown(0);
            return;
        }

        base.OnStartup(e);
        ApplySystemTheme();
        _tray = new TrayController();
        _singleInstance!.StartActivationListener(() =>
        {
            Current.Dispatcher.BeginInvoke(() => _tray?.ShowFlyoutFromActivation());
        });
        _tray.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        ShellLogger.Instance.Info("lifecycle", "OpenUsage shell exiting");
        _tray?.Dispose();
        _singleInstance?.Dispose();
        base.OnExit(e);
    }

    private static void RegisterExceptionHandlers()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            var ex = args.ExceptionObject as Exception;
            ShellLogger.Instance.Error("crash", "Unhandled AppDomain exception", ex ?? new Exception("unknown"));
        };

        Current.DispatcherUnhandledException += (_, args) =>
        {
            ShellLogger.Instance.Error("crash", "Unhandled dispatcher exception", args.Exception);
            args.Handled = true;
        };

        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            ShellLogger.Instance.Error("crash", "Unobserved task exception", args.Exception);
            args.SetObserved();
        };
    }

    private static void ApplySystemTheme()
    {
        var isDark = IsWindowsDarkTheme();
        var resources = Current.Resources;
        if (isDark)
        {
            resources["FlyoutBackgroundBrush"] = new SolidColorBrush(System.Windows.Media.Color.FromRgb(0x2D, 0x2D, 0x2D));
            resources["FlyoutBorderBrush"] = new SolidColorBrush(System.Windows.Media.Color.FromRgb(0x3D, 0x3D, 0x3D));
            resources["CardBackgroundBrush"] = new SolidColorBrush(System.Windows.Media.Color.FromRgb(0x38, 0x38, 0x38));
            resources["PrimaryTextBrush"] = new SolidColorBrush(System.Windows.Media.Color.FromRgb(0xF0, 0xF0, 0xF0));
            resources["SecondaryTextBrush"] = new SolidColorBrush(System.Windows.Media.Color.FromRgb(0xB0, 0xB0, 0xB0));
        }
    }

    private static bool IsWindowsDarkTheme()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var value = key?.GetValue("AppsUseLightTheme");
            return value is int i && i == 0;
        }
        catch
        {
            return false;
        }
    }
}

internal sealed class TrayController : IDisposable
{
    private readonly WinForms.NotifyIcon _notifyIcon;
    private readonly SidecarSupervisor _supervisor = new();
    private readonly SidecarClient _client = new();
    private readonly ShellSettings _settings;
    private readonly FloatingStripWindow _strip;
    private FlyoutWindow? _flyout;
    private bool _flyoutLayoutHooked;
    private UpdateInfo? _pendingUpdate;
    private System.Drawing.Icon? _trayIcon;
    private readonly DispatcherTimer _reconnectTimer;
    private readonly DispatcherTimer _periodicRefreshTimer;
    private bool _refreshInFlight;

    /// <summary>Same fixed cadence as macOS <c>RefreshSetting.interval</c> (5 minutes).</summary>
    private static readonly TimeSpan PeriodicRefreshInterval = TimeSpan.FromMinutes(5);

    public TrayController()
    {
        _settings = ShellSettings.Load();
        AutoStartManager.SyncFromSettings(_settings);

        _strip = new FloatingStripWindow();
        _strip.OpenFlyoutRequested += ShowFlyoutFromStrip;
        _strip.ContextMenuRequested += () => ShowTrayContextMenu();
        _strip.PositionChanged += (left, top) =>
        {
            _settings.StripLeft = left;
            _settings.StripTop = top;
            _settings.Save();
        };

        _trayIcon = TrayIconRenderer.CreateLogo();
        _notifyIcon = new WinForms.NotifyIcon
        {
            Text = "OpenUsage",
            Icon = _trayIcon,
            Visible = true
        };
        _notifyIcon.MouseClick += OnTrayClick;
        _notifyIcon.ContextMenuStrip = BuildContextMenu();

        _reconnectTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _reconnectTimer.Tick += async (_, _) => await RefreshFlyoutAsync();

        _periodicRefreshTimer = new DispatcherTimer { Interval = PeriodicRefreshInterval };
        _periodicRefreshTimer.Tick += async (_, _) =>
        {
            ShellLogger.Instance.Info("refresh", "Periodic refresh tick");
            await RefreshAllAsync();
        };

        _supervisor.SidecarExited += () =>
        {
            WpfApplication.Current.Dispatcher.BeginInvoke(() => _client.Disconnect());
        };
    }

    public void Start()
    {
        TrayActions.RegisterRefresh(() => _ = RefreshAllAsync());
        TrayActions.RegisterLaunchAtLoginChanged(OnLaunchAtLoginChanged);
        _strip.Show();
        // Apply after first layout so Width/Height are real when clamping.
        _strip.Dispatcher.BeginInvoke(() =>
        {
            _strip.ApplyPosition(_settings.StripLeft, _settings.StripTop);
        }, System.Windows.Threading.DispatcherPriority.Loaded);
        _strip.Update([]);
        _ = InitializeAsync();
        _ = CheckForUpdatesAsync();
    }

    private void ShowTrayContextMenu()
    {
        _notifyIcon.ContextMenuStrip?.Show(WinForms.Control.MousePosition);
    }

    private void ApplyTraySummary(IReadOnlyList<SidecarProvider> providers)
    {
        var summary = TrayMetricSummary.FromProviders(providers);
        var segments = StripContentBuilder.Build(providers);
        ShellLogger.Instance.Info(
            "strip",
            $"providers={providers.Count} segments={segments.Count} tip={TruncateTrayTip(summary.Tooltip)}");
        _strip.Update(segments);
        _notifyIcon.Text = TruncateTrayTip(summary.Tooltip);
        // Tray icon stays the OpenUsage brand mark (macOS menu-bar logo equivalent).
    }

    private static string TruncateTrayTip(string tooltip)
    {
        var oneLine = tooltip.Replace("\n", " · ");
        return oneLine.Length <= 63 ? oneLine : oneLine[..60] + "…";
    }

    public void ShowFlyoutFromActivation()
    {
        ShellLogger.Instance.Info("single-instance", "Showing flyout from activation signal");
        ShowFlyout();
    }

    private void ShowFlyoutFromStrip()
    {
        // Strip click/double-click always opens (or focuses) — never toggles closed mid-gesture.
        if (_flyout is { IsVisible: true })
        {
            PositionFlyout(_flyout);
            _flyout.Activate();
            return;
        }

        ShowFlyout();
    }

    private WinForms.ContextMenuStrip BuildContextMenu()
    {
        var menu = new WinForms.ContextMenuStrip();

        var refresh = new WinForms.ToolStripMenuItem("Refresh");
        refresh.Click += async (_, _) => await RefreshAllAsync();

        var launchAtLogin = new WinForms.ToolStripMenuItem("Launch at Login")
        {
            CheckOnClick = true,
            Checked = _settings.LaunchAtLogin
        };
        launchAtLogin.Click += (_, _) =>
        {
            _settings.LaunchAtLogin = launchAtLogin.Checked;
            _settings.Save();
            try
            {
                AutoStartManager.SetEnabled(launchAtLogin.Checked);
            }
            catch
            {
                launchAtLogin.Checked = AutoStartManager.IsEnabled();
                _settings.LaunchAtLogin = launchAtLogin.Checked;
                _settings.Save();
            }

            _flyout?.SetLaunchAtLogin(launchAtLogin.Checked);
        };

        var testToast = new WinForms.ToolStripMenuItem("Test Notification");
        testToast.Click += (_, _) =>
        {
            try
            {
                ToastService.Show("OpenUsage", "Test notification from the Windows spike.");
            }
            catch (Exception ex)
            {
                _flyout?.SetError($"Toast failed: {ex.Message}");
            }
        };

        var quit = new WinForms.ToolStripMenuItem("Quit");
        quit.Click += (_, _) => Shutdown();

        menu.Items.Add(refresh);
        menu.Items.Add(launchAtLogin);
        menu.Items.Add(testToast);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(quit);
        return menu;
    }

    private void OnLaunchAtLoginChanged(bool enabled)
    {
        _settings.LaunchAtLogin = enabled;
        _settings.Save();
        try
        {
            AutoStartManager.SetEnabled(enabled);
        }
        catch
        {
            enabled = AutoStartManager.IsEnabled();
            _settings.LaunchAtLogin = enabled;
            _settings.Save();
        }

        _flyout?.SetLaunchAtLogin(enabled);

        foreach (WinForms.ToolStripItem item in _notifyIcon.ContextMenuStrip!.Items)
        {
            if (item is WinForms.ToolStripMenuItem menu && menu.Text == "Launch at Login")
            {
                menu.Checked = enabled;
                break;
            }
        }
    }

    private void OnTrayClick(object? sender, WinForms.MouseEventArgs e)
    {
        if (e.Button == WinForms.MouseButtons.Left)
        {
            ToggleFlyout();
        }
    }

    private void ToggleFlyout()
    {
        if (_flyout is { IsVisible: true })
        {
            _flyout.Hide();
            return;
        }
        ShowFlyout();
    }

    private void ShowFlyout(string? banner = null)
    {
        _flyout ??= new FlyoutWindow();
        if (!_flyoutLayoutHooked)
        {
            _flyout.LayoutSettled += () =>
            {
                if (_flyout is { IsVisible: true })
                {
                    PositionFlyout(_flyout);
                }
            };
            _flyoutLayoutHooked = true;
        }

        _flyout.SetLaunchAtLogin(_settings.LaunchAtLogin);
        if (banner is not null)
        {
            _flyout.SetBanner(banner);
        }
        else
        {
            ApplyPendingUpdateBanner();
        }

        // Hide until anchored — first open used to grow downward from a too-low Top
        // because SizeToContent hadn't measured provider cards yet.
        _flyout.Opacity = 0;
        _flyout.Show();
        PositionFlyout(_flyout);
        _flyout.Dispatcher.BeginInvoke(() =>
        {
            PositionFlyout(_flyout);
            _flyout.Opacity = 1;
            _flyout.Activate();
        }, System.Windows.Threading.DispatcherPriority.Loaded);
        _ = RefreshFlyoutAsync();
    }

    private static void PositionFlyout(Window flyout)
    {
        var work = SystemParameters.WorkArea;
        flyout.UpdateLayout();
        var width = flyout.ActualWidth > 0 ? flyout.ActualWidth : flyout.Width;
        var height = flyout.ActualHeight > 0 ? flyout.ActualHeight : flyout.Height;
        if (double.IsNaN(width) || width <= 0)
        {
            width = 372;
        }

        if (double.IsNaN(height) || height <= 0)
        {
            // Prefer a tall estimate so Top starts high; content then grows downward into place.
            height = Math.Min(work.Height * 0.75, 720);
        }

        double left = work.Right - width - 12;
        double top = work.Bottom - height - 12;
        flyout.Left = Math.Max(work.Left + 8, left);
        flyout.Top = Math.Max(work.Top + 8, top);
    }

    private async Task InitializeAsync()
    {
        await EnsureConnectedAsync();
        await RefreshFlyoutAsync();
        // First live numbers are on screen — keep them fresh on the same 5-minute cadence as macOS.
        _periodicRefreshTimer.Start();
        ShellLogger.Instance.Info("refresh", $"Periodic refresh every {PeriodicRefreshInterval.TotalMinutes:0}m");
    }

    private async Task RefreshAllAsync()
    {
        if (_refreshInFlight)
        {
            return;
        }

        _refreshInFlight = true;
        _flyout?.SetRefreshing(true);
        try
        {
            await EnsureConnectedAsync();
            await Task.Run(() => _client.Send(new SidecarRequest { Op = "refresh", Provider = "all" }))
                .ConfigureAwait(true);
            await RefreshFlyoutAsync();
            // Manual or periodic success resets the 5-minute clock so we don't double-hit.
            _periodicRefreshTimer.Stop();
            _periodicRefreshTimer.Start();
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Error("sidecar", "Refresh failed", ex);
            _flyout?.SetError(ex.Message);
        }
        finally
        {
            _refreshInFlight = false;
            _flyout?.SetRefreshing(false);
        }
    }

    private async Task RefreshFlyoutAsync()
    {
        await EnsureConnectedAsync();
        try
        {
            var response = await Task.Run(() => _client.Send(new SidecarRequest { Op = "snapshot" }))
                .ConfigureAwait(true);
            if (response.Op == "error")
            {
                _flyout?.SetError(response.Message ?? "Unknown sidecar error");
                return;
            }

            var providers = response.Providers ?? [];
            ApplyTraySummary(providers);
            _flyout?.SetProviders(providers);
            EvaluateQuotaToasts(providers);
            _reconnectTimer.Stop();
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("sidecar", $"Snapshot failed: {ex.Message}");
            _flyout?.SetError(ex.Message);
            _client.Disconnect();
            _reconnectTimer.Start();
        }
    }

    private void EvaluateQuotaToasts(IReadOnlyList<SidecarProvider> providers)
    {
        foreach (var alert in QuotaToastEvaluator.FindAlerts(providers))
        {
            var key = QuotaToastEvaluator.DedupeKey(alert);
            if (!_settings.ShouldShowQuotaToast(key))
            {
                continue;
            }

            try
            {
                ToastService.Show(
                    $"{alert.ProviderName} usage",
                    $"{alert.Label} is at {alert.Percent}% of its limit.");
                _settings.MarkQuotaToastShown(key);
                ShellLogger.Instance.Info("toast", $"Quota alert shown for {key}");
            }
            catch (Exception ex)
            {
                ShellLogger.Instance.Warn("toast", $"Quota toast failed for {key}: {ex.Message}");
            }
        }
    }

    private async Task CheckForUpdatesAsync()
    {
        try
        {
            var checker = new UpdateChecker();
            var update = await checker.CheckForUpdateAsync().ConfigureAwait(false);
            if (update is null)
            {
                return;
            }

            WpfApplication.Current.Dispatcher.BeginInvoke(() =>
            {
                _pendingUpdate = update;
                ApplyPendingUpdateBanner();
            });
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("updater", $"Update check failed: {ex.Message}");
        }
    }

    private void ApplyPendingUpdateBanner()
    {
        if (_pendingUpdate is null || _flyout is null)
        {
            return;
        }

        _flyout.SetUpdateBanner(_pendingUpdate.Version, _pendingUpdate.Url);
    }

    private async Task EnsureConnectedAsync()
    {
        if (!_supervisor.EnsureRunning())
        {
            _flyout?.SetError(_supervisor.LastError ?? "Sidecar unavailable");
            await Task.Delay(500);
        }

        // Sidecar only opens the pipe after the first provider refresh (~30–70s cold start).
        // Run Connect off the UI thread and keep retrying long enough to cover that window.
        for (var attempt = 0; attempt < 40; attempt++)
        {
            try
            {
                await Task.Run(() => _client.Connect(timeoutMs: 2_000)).ConfigureAwait(true);
                var pong = await Task.Run(() => _client.Send(new SidecarRequest { Op = "ping" }))
                    .ConfigureAwait(true);
                if (pong.Op == "pong")
                {
                    _reconnectTimer.Stop();
                    ShellLogger.Instance.Info("sidecar", "Connected to pipe");
                    return;
                }
            }
            catch (Exception ex)
            {
                _client.Disconnect();
                if (attempt == 0 || attempt % 5 == 4)
                {
                    ShellLogger.Instance.Warn("sidecar", $"Connect attempt {attempt + 1}: {ex.Message}");
                }

                await Task.Delay(1_000).ConfigureAwait(true);
            }
        }

        _reconnectTimer.Start();
        _flyout?.SetError(_supervisor.LastError ?? "Could not connect to sidecar pipe");
        _strip.Update([]);
    }

    private void Shutdown()
    {
        ShellLogger.Instance.Info("lifecycle", "Quit requested");
        _supervisor.Stop();
        _notifyIcon.Visible = false;
        WpfApplication.Current.Shutdown();
    }

    public void Dispose()
    {
        _periodicRefreshTimer.Stop();
        _reconnectTimer.Stop();
        _client.Dispose();
        _supervisor.Dispose();
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _trayIcon?.Dispose();
        _strip.Close();
        _flyout?.Close();
    }
}
