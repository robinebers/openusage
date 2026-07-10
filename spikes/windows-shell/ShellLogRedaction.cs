using System.Text.RegularExpressions;

namespace OpenUsageShell;

/// <summary>
/// Lightweight log redaction for the shell (mirrors core LogRedaction.redactLogMessage patterns).
/// </summary>
internal static partial class ShellLogRedaction
{
    [GeneratedRegex(@"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+")]
    private static partial Regex JwtRegex();

    [GeneratedRegex(@"(sk-|pk-|api_|key_|secret_)[A-Za-z0-9_-]{12,}")]
    private static partial Regex ApiKeyRegex();

    [GeneratedRegex(@"Bearer\s+[A-Za-z0-9._\-]+", RegexOptions.IgnoreCase)]
    private static partial Regex BearerRegex();

    public static string Redact(string message)
    {
        var result = JwtRegex().Replace(message, m => MaskValue(m.Value));
        result = ApiKeyRegex().Replace(result, m => MaskValue(m.Value));
        result = BearerRegex().Replace(result, "Bearer [REDACTED]");
        return result;
    }

    private static string MaskValue(string value)
    {
        if (value.Length <= 12)
        {
            return "[REDACTED]";
        }

        return $"{value[..4]}...{value[^4..]}";
    }
}
