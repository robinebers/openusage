using UsageMeter.Core;

namespace UsageMeter.App;

internal sealed class ProviderViewModel
{
    public ProviderViewModel(ProviderUsageResult result)
    {
        Id = result.ProviderId;
        Name = result.ProviderName;
        IsAvailable = result.IsAvailable;
        Plan = result.Plan ?? string.Empty;
        Error = result.Error ?? string.Empty;
        Lines = result.Lines.Select(line => new MetricLineViewModel(line)).ToList();
    }

    public string Id { get; }
    public string Name { get; }
    public bool IsAvailable { get; }
    public string Plan { get; }
    public string Error { get; }
    public IReadOnlyList<MetricLineViewModel> Lines { get; }
}

internal sealed class MetricLineViewModel
{
    public MetricLineViewModel(MetricLine line)
    {
        Kind = line.Kind;
        Label = line.Label;
        Value = line.Value;
        Progress = line.ProgressPercent;
        ResetText = FormatReset(line.ResetsAt);
    }

    public MetricLineKind Kind { get; }
    public string Label { get; }
    public string? Value { get; }
    public double? Progress { get; }
    public string? ResetText { get; }
    public string LeftText => Progress.HasValue ? $"{Math.Max(0, 100 - Progress.Value):0}% left" : Value ?? string.Empty;

    private static string? FormatReset(DateTimeOffset? resetsAt)
    {
        if (resetsAt is null)
        {
            return null;
        }

        var remaining = resetsAt.Value - DateTimeOffset.Now;
        if (remaining <= TimeSpan.Zero)
        {
            return "Resets soon";
        }

        if (remaining.TotalDays >= 1)
        {
            return $"Resets in {(int)remaining.TotalDays}d {remaining.Hours}h";
        }

        return $"Resets in {(int)remaining.TotalHours}h {remaining.Minutes}m";
    }
}
