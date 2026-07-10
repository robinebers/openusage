using Microsoft.Win32;

namespace OpenUsageShell;

/// <summary>
/// Unpackaged launch-at-login via HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
/// </summary>
internal static class AutoStartManager
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "OpenUsage";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            var value = key?.GetValue(ValueName) as string;
            return !string.IsNullOrWhiteSpace(value);
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("autostart", $"Registry read failed: {ex.Message}");
            return false;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
                            ?? Registry.CurrentUser.CreateSubKey(RunKeyPath);

            if (enabled)
            {
                var exe = ShellPaths.ShellExecutablePath;
                key.SetValue(ValueName, $"\"{exe}\"");
                ShellLogger.Instance.Info("autostart", $"Enabled launch at login -> {exe}");
            }
            else
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
                ShellLogger.Instance.Info("autostart", "Disabled launch at login");
            }
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Error("autostart", "Failed to update Run registry", ex);
            throw;
        }
    }

    public static void SyncFromSettings(ShellSettings settings)
    {
        var registryEnabled = IsEnabled();
        if (settings.LaunchAtLogin && !registryEnabled)
        {
            SetEnabled(true);
        }
        else if (!settings.LaunchAtLogin && registryEnabled)
        {
            SetEnabled(false);
        }
    }
}
