using UsageMeter.Core;

namespace UsageMeter.Tests;

public sealed class WindowsPathsTests
{
    [Fact]
    public void ExpandHomePath_ExpandsTilde()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        var expanded = new WindowsPaths().Expand("~/.codex/auth.json");

        Assert.Equal(Path.Combine(home, ".codex", "auth.json"), expanded);
    }

    [Fact]
    public void UsageMeterDataDir_UsesLocalAppData()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        Assert.Equal(Path.Combine(localAppData, "UsageMeter"), new WindowsPaths().UsageMeterDataDir);
    }
}
