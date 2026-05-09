using UsageMeter.Core;

namespace UsageMeter.Tests;

public sealed class ModelsTests
{
    [Fact]
    public void ProviderUsageResultUnavailable_CarriesMessage()
    {
        var result = ProviderUsageResult.Unavailable("Codex", "No auth file");

        Assert.Equal("Codex", result.ProviderName);
        Assert.False(result.IsAvailable);
        Assert.Equal("No auth file", result.Message);
        var line = Assert.Single(result.Lines);
        Assert.Equal("Status", line.Label);
        Assert.Equal("No auth file", line.Value);
    }

    [Fact]
    public void MetricLineProgress_ClampsPercent()
    {
        var line = MetricLine.Progress("Weekly", 130, "130%");

        Assert.Equal("Weekly", line.Label);
        Assert.Equal(100, line.ProgressPercent);
        Assert.Equal("130%", line.Value);
    }
}
