namespace UsageMeter.Core;

public sealed class WindowsPaths
{
    public string Home { get; } = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public string AppData { get; } = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    public string LocalAppData { get; } = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    public string UsageMeterDataDir
    {
        get
        {
            var path = Path.Combine(LocalAppData, "UsageMeter");
            Directory.CreateDirectory(path);
            return path;
        }
    }

    public string Expand(string path)
    {
        if (path == "~")
        {
            return Home;
        }

        if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal))
        {
            return Path.Combine(Home, path[2..].Replace('/', Path.DirectorySeparatorChar));
        }

        return Environment.ExpandEnvironmentVariables(path.Replace('/', Path.DirectorySeparatorChar));
    }
}
