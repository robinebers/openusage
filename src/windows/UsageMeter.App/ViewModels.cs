using UsageMeter.Core;

namespace UsageMeter.App;

internal sealed class ProviderViewModel
{
    public ProviderViewModel(ProviderUsageResult result)
    {
        Name = result.ProviderName;
        IsAvailable = result.IsAvailable;
        Message = result.Message ?? string.Empty;
        Lines = result.Lines.Select(line => new MetricLineViewModel(line)).ToList();
    }

    public string Name { get; }
    public bool IsAvailable { get; }
    public string Status => IsAvailable ? "Connected" : "Unavailable";
    public string Message { get; }
    public IReadOnlyList<MetricLineViewModel> Lines { get; }
}

internal sealed class MetricLineViewModel
{
    public MetricLineViewModel(MetricLine line)
    {
        Label = line.Label;
        Value = line.Value;
        Progress = line.ProgressPercent;
    }

    public string Label { get; }
    public string? Value { get; }
    public double? Progress { get; }
}
