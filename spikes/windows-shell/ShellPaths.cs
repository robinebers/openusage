namespace OpenUsageShell;

internal static class ShellPaths
{
    public static string OpenUsageRoot =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OpenUsage");

    public static string SettingsPath => Path.Combine(OpenUsageRoot, "settings.json");

    public static string LogsDirectory => Path.Combine(OpenUsageRoot, "logs");

    public static string ShellLogPath => Path.Combine(LogsDirectory, "shell.log");

    public static string ShellExecutablePath =>
        Environment.ProcessPath
        ?? Path.Combine(AppContext.BaseDirectory, "OpenUsageShell.exe");

    public static void EnsureDirectories()
    {
        Directory.CreateDirectory(OpenUsageRoot);
        Directory.CreateDirectory(LogsDirectory);
    }
}
