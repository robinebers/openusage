using System.Text.Json;
using UsageMeter.Core.Providers;

namespace UsageMeter.Core;

public sealed class UsageMeterService
{
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private readonly WindowsPaths _paths;

    public UsageMeterService(WindowsPaths paths, IEnumerable<IUsageProvider> providers)
    {
        _paths = paths;
        Providers = providers.ToArray();
    }

    public IReadOnlyList<IUsageProvider> Providers { get; }
    public UsageSnapshot Snapshot { get; private set; } = UsageSnapshot.Empty;

    public async Task<UsageSnapshot> RefreshAsync(CancellationToken cancellationToken = default)
    {
        await _refreshLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var results = await Task.WhenAll(Providers.Select(provider => provider.ProbeAsync(cancellationToken))).ConfigureAwait(false);
            Snapshot = new UsageSnapshot(results, DateTimeOffset.Now);
            SaveSnapshot(Snapshot);
            return Snapshot;
        }
        finally
        {
            _refreshLock.Release();
        }
    }

    private void SaveSnapshot(UsageSnapshot snapshot)
    {
        var path = Path.Combine(_paths.UsageMeterDataDir, "usage-cache.json");
        File.WriteAllText(path, JsonSerializer.Serialize(snapshot, Json.WebOptions));
    }

    public static UsageMeterService CreateDefault()
    {
        var paths = new WindowsPaths();
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
        var sqlite = new SqliteReader(paths);
        IUsageProvider[] providers =
        [
            new CodexProvider(paths, http),
            new ClaudeProvider(paths, http),
            new CursorProvider(paths, http, sqlite),
            new CopilotProvider(paths, http),
            new GeminiProvider(paths, http),
            new OpenCodeGoProvider(paths, http, sqlite),
            new WindsurfProvider(paths, http, sqlite)
        ];
        return new UsageMeterService(paths, providers);
    }
}
