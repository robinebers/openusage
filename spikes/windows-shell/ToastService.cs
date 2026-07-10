using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using CommunityToolkit.WinUI.Notifications;

namespace OpenUsageShell;

/// <summary>
/// Unpackaged toast path — brand name/icon come from <see cref="AppIdentity"/> Start Menu shortcut.
/// </summary>
internal static class ToastService
{
    private static bool _initialized;
    private static string? _logoPath;

    public static void Initialize()
    {
        if (_initialized)
        {
            return;
        }

        AppIdentity.EnsureRegistered();
        _logoPath = EnsureToastLogoPng();

        ToastNotificationManagerCompat.OnActivated += _ =>
        {
            ShellLogger.Instance.Info("toast", "Toast activation received");
        };

        _initialized = true;
        ShellLogger.Instance.Info("toast", $"Toast notifier ready (AUMID={AppIdentity.AppUserModelId}, logo={_logoPath is not null})");
    }

    public static void Show(string title, string message)
    {
        Initialize();
        try
        {
            var builder = new ToastContentBuilder()
                .AddText(title)
                .AddText(message);

            if (_logoPath is not null && File.Exists(_logoPath))
            {
                // Circle crop matches Win11 toast chrome; logo already drawn on a round plate.
                builder.AddAppLogoOverride(new Uri(_logoPath), ToastGenericAppLogoCrop.Circle);
            }

            builder.Show();
            ShellLogger.Instance.Info("toast", $"Shown: {title} — {message}");
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Error("toast", "Failed to show notification", ex);
            throw;
        }
    }

    private static string? EnsureToastLogoPng()
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OpenUsage");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "toast-logo.png");

            // Always refresh — keeps toast body logo in sync with brand polish.
            using var bmp = TrayIconRenderer.RenderAppIconBitmap(128);
            bmp.Save(path, ImageFormat.Png);
            return path;
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("toast", $"Toast logo export failed: {ex.Message}");
            return null;
        }
    }
}
