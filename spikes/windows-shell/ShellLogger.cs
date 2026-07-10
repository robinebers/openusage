namespace OpenUsageShell;

internal sealed class ShellLogger
{
    private static readonly object Lock = new();
    private static ShellLogger? _instance;

    public static ShellLogger Instance => _instance ??= new ShellLogger();

    private ShellLogger()
    {
        ShellPaths.EnsureDirectories();
    }

    public void Info(string tag, string message) => Write("INFO", tag, message);

    public void Warn(string tag, string message) => Write("WARN", tag, message);

    public void Error(string tag, string message) => Write("ERROR", tag, message);

    public void Error(string tag, string message, Exception ex) =>
        Write("ERROR", tag, $"{message}: {ex.GetType().Name}: {ex.Message}");

    private static void Write(string level, string tag, string message)
    {
        var redacted = ShellLogRedaction.Redact(message);
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd'T'HH:mm:ss.fffK} [{level}] [{tag}] {redacted}";
        lock (Lock)
        {
            try
            {
                File.AppendAllText(ShellPaths.ShellLogPath, line + Environment.NewLine);
            }
            catch
            {
                // Best effort — never crash the shell for logging failures.
            }
        }
    }
}
