using System.Diagnostics;

namespace OpenUsageShell;

/// <summary>
/// Supervises the Swift sidecar process: launch, restart with backoff, kill on shutdown.
/// Ensures at most one sidecar.exe is alive for this shell (kills orphans on launch).
/// </summary>
internal sealed class SidecarSupervisor : IDisposable
{
    private readonly object _lock = new();
    private Process? _process;
    private bool _shuttingDown;
    private int _restartAttempts;
    private Task? _restartTask;

    public string? LastError { get; private set; }

    public event Action? SidecarExited;

    public bool EnsureRunning()
    {
        lock (_lock)
        {
            if (_shuttingDown)
            {
                return false;
            }

            if (_process is { HasExited: false })
            {
                return true;
            }

            return LaunchLocked();
        }
    }

    public void Stop()
    {
        lock (_lock)
        {
            _shuttingDown = true;
            KillProcessLocked();
        }

        try
        {
            _restartTask?.Wait(TimeSpan.FromSeconds(5));
        }
        catch
        {
            // ignore
        }
    }

    private bool LaunchLocked()
    {
        var exe = LocateSidecarExecutable();
        if (exe is null)
        {
            LastError = "sidecar.exe not found. Build spikes/windows-core first: swift build --product sidecar";
            ShellLogger.Instance.Error("sidecar", LastError);
            return false;
        }

        // Kill any leftover sidecar from a previous shell crash / hot-reload before we start ours.
        KillOrphanSidecars(exceptPid: null);

        try
        {
            _process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = exe,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = Path.GetDirectoryName(exe) ?? Environment.CurrentDirectory
                },
                EnableRaisingEvents = true
            };
            _process.Exited += OnProcessExited;
            _process.Start();
            _restartAttempts = 0;
            LastError = null;
            ShellLogger.Instance.Info("sidecar", $"Started pid={_process.Id} path={exe}");
            return true;
        }
        catch (Exception ex)
        {
            LastError = $"Failed to launch sidecar: {ex.Message}";
            ShellLogger.Instance.Error("sidecar", LastError, ex);
            return false;
        }
    }

    private void OnProcessExited(object? sender, EventArgs e)
    {
        int? exitCode = null;
        int? pid = null;
        lock (_lock)
        {
            if (_process is not null)
            {
                pid = _process.Id;
                exitCode = _process.ExitCode;
            }
        }

        ShellLogger.Instance.Warn("sidecar", $"Process exited pid={pid} code={exitCode}");
        SidecarExited?.Invoke();

        lock (_lock)
        {
            if (_shuttingDown)
            {
                return;
            }

            _restartAttempts++;
            var delayMs = Math.Min(30_000, 1_000 * (1 << Math.Min(_restartAttempts - 1, 4)));
            ShellLogger.Instance.Info("sidecar", $"Scheduling restart in {delayMs}ms (attempt {_restartAttempts})");
            _restartTask = Task.Run(async () =>
            {
                await Task.Delay(delayMs);
                lock (_lock)
                {
                    if (_shuttingDown)
                    {
                        return;
                    }

                    LaunchLocked();
                }
            });
        }
    }

    private void KillProcessLocked()
    {
        if (_process is { HasExited: false })
        {
            try
            {
                ShellLogger.Instance.Info("sidecar", $"Stopping pid={_process.Id}");
                _process.Kill(entireProcessTree: true);
            }
            catch (Exception ex)
            {
                ShellLogger.Instance.Warn("sidecar", $"Kill failed: {ex.Message}");
            }
        }

        _process?.Dispose();
        _process = null;
        KillOrphanSidecars(exceptPid: null);
    }

    /// <summary>
    /// Ends any other <c>sidecar</c> processes so hot-reloads and crashed shells don't leave duplicates.
    /// </summary>
    private static void KillOrphanSidecars(int? exceptPid)
    {
        foreach (var p in Process.GetProcessesByName("sidecar"))
        {
            try
            {
                if (exceptPid is int keep && p.Id == keep)
                {
                    continue;
                }

                ShellLogger.Instance.Info("sidecar", $"Stopping orphan pid={p.Id}");
                p.Kill(entireProcessTree: true);
                p.WaitForExit(3_000);
            }
            catch (Exception ex)
            {
                ShellLogger.Instance.Warn("sidecar", $"Orphan kill failed pid={p.Id}: {ex.Message}");
            }
            finally
            {
                p.Dispose();
            }
        }
    }

    private static string? LocateSidecarExecutable()
    {
        var candidates = new List<string>();

        var env = Environment.GetEnvironmentVariable("OPENUSAGE_SIDECAR");
        if (!string.IsNullOrWhiteSpace(env))
        {
            candidates.Add(env);
        }

        var cwd = Environment.CurrentDirectory;
        candidates.Add(Path.Combine(cwd, "sidecar.exe"));
        candidates.Add(Path.Combine(cwd, ".build", "x86_64-unknown-windows-msvc", "debug", "sidecar.exe"));
        candidates.Add(Path.Combine(cwd, ".build", "x86_64-unknown-windows-msvc", "release", "sidecar.exe"));

        var dir = new DirectoryInfo(cwd);
        for (var i = 0; i < 8 && dir is not null; i++, dir = dir.Parent!)
        {
            var spike = Path.Combine(dir.FullName, "spikes", "windows-core");
            candidates.Add(Path.Combine(spike, ".build", "x86_64-unknown-windows-msvc", "debug", "sidecar.exe"));
            candidates.Add(Path.Combine(spike, ".build", "x86_64-unknown-windows-msvc", "release", "sidecar.exe"));
        }

        return candidates.FirstOrDefault(File.Exists);
    }

    public void Dispose() => Stop();
}
