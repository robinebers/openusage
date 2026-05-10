namespace UsageMeter.Core;

public enum MetricLineKind
{
    Text,
    Progress,
    Badge
}

public enum ProgressFormatKind
{
    Percent,
    Dollars,
    Count
}

public sealed record MetricLine(
    MetricLineKind Kind,
    string Label,
    string? Value = null,
    double? Used = null,
    double? Limit = null,
    ProgressFormatKind? Format = null,
    string? Suffix = null,
    DateTimeOffset? ResetsAt = null,
    TimeSpan? PeriodDuration = null,
    string? Color = null,
    string? Subtitle = null)
{
    public static MetricLine Text(string label, string value, string? subtitle = null) =>
        new(MetricLineKind.Text, label, Value: value, Subtitle: subtitle);

    public static MetricLine Badge(string label, string value, string? color = null, string? subtitle = null) =>
        new(MetricLineKind.Badge, label, Value: value, Color: color, Subtitle: subtitle);

    public static MetricLine Progress(
        string label,
        double used,
        double limit,
        ProgressFormatKind format = ProgressFormatKind.Percent,
        string? suffix = null,
        DateTimeOffset? resetsAt = null,
        TimeSpan? periodDuration = null,
        string? color = null) =>
        new(MetricLineKind.Progress, label, Used: used, Limit: limit, Format: format, Suffix: suffix, ResetsAt: resetsAt, PeriodDuration: periodDuration, Color: color);

    public static MetricLine Progress(string label, double percent, string value) =>
        new(MetricLineKind.Progress, label, Value: value, Used: Math.Clamp(percent, 0, 100), Limit: 100, Format: ProgressFormatKind.Percent);

    public double? ProgressPercent => Used is null || Limit is null || Limit <= 0
        ? null
        : Math.Clamp((Used.Value / Limit.Value) * 100, 0, 100);
}

public sealed record ProviderUsageResult(
    string ProviderId,
    string DisplayName,
    string? Plan,
    IReadOnlyList<MetricLine> Lines,
    DateTimeOffset LastUpdatedAt,
    string? Error = null)
{
    public string ProviderName => DisplayName;
    public bool IsAvailable => !HasError;
    public bool HasError => !string.IsNullOrWhiteSpace(Error);
    public string? Message => Error ?? Plan;

    public static ProviderUsageResult Failure(string providerId, string displayName, string message) =>
        new(providerId, displayName, null, [MetricLine.Badge("Status", message, "#dc2626")], DateTimeOffset.Now, message);

    public static ProviderUsageResult Unavailable(string displayName, string message) =>
        Failure(displayName.ToLowerInvariant().Replace(' ', '-'), displayName, message);
}

public interface IUsageProvider
{
    string Id { get; }
    string DisplayName { get; }
    Task<ProviderUsageResult> ProbeAsync(CancellationToken cancellationToken);
}

public sealed record UsageSnapshot(IReadOnlyList<ProviderUsageResult> Providers, DateTimeOffset UpdatedAt)
{
    public static UsageSnapshot Empty { get; } = new([], DateTimeOffset.MinValue);
}
