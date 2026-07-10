using System.IO;
using System.IO.Pipes;
using System.Text;

namespace OpenUsageShell;

/// <summary>
/// Ensures one shell instance per user session. Second launch signals the first to show the flyout.
/// </summary>
internal sealed class SingleInstanceManager : IDisposable
{
    private const string MutexName = @"Local\OpenUsageShell";
    public static string ActivationPipeName => $"OpenUsageShell-{Environment.UserName}";

    private readonly Mutex _mutex;
    private readonly bool _isPrimary;
    private CancellationTokenSource? _listenerCts;
    private Task? _listenerTask;
    private Action? _onShowRequested;

    private SingleInstanceManager(Mutex mutex, bool isPrimary)
    {
        _mutex = mutex;
        _isPrimary = isPrimary;
    }

    public bool IsPrimary => _isPrimary;

    public static bool TryBecomePrimary(out SingleInstanceManager? manager)
    {
        var mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (!createdNew)
        {
            SignalExistingInstance();
            mutex.Dispose();
            manager = null;
            return false;
        }

        manager = new SingleInstanceManager(mutex, isPrimary: true);
        return true;
    }

    public void StartActivationListener(Action onShowRequested)
    {
        if (!_isPrimary)
        {
            return;
        }

        _onShowRequested = onShowRequested;
        _listenerCts = new CancellationTokenSource();
        _listenerTask = Task.Run(() => ListenLoop(_listenerCts.Token));
        ShellLogger.Instance.Info("single-instance", $"Primary instance; activation pipe={ActivationPipeName}");
    }

    private static void SignalExistingInstance()
    {
        ShellLogger.Instance.Info("single-instance", "Another instance is running; signaling show flyout");
        try
        {
            using var client = new NamedPipeClientStream(".", ActivationPipeName, PipeDirection.Out);
            client.Connect(timeout: 2_000);
            using var writer = new StreamWriter(client, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            writer.WriteLine("show");
        }
        catch (Exception ex)
        {
            ShellLogger.Instance.Warn("single-instance", $"Could not signal existing instance: {ex.Message}");
        }
    }

    private void ListenLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(
                    ActivationPipeName,
                    PipeDirection.In,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);

                server.WaitForConnection();
                using var reader = new StreamReader(server, Encoding.UTF8, leaveOpen: true);
                var line = reader.ReadLine();
                if (string.Equals(line, "show", StringComparison.OrdinalIgnoreCase))
                {
                    ShellLogger.Instance.Info("single-instance", "Received show request from second instance");
                    _onShowRequested?.Invoke();
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                ShellLogger.Instance.Warn("single-instance", $"Activation listener error: {ex.Message}");
                Thread.Sleep(500);
            }
        }
    }

    public void Dispose()
    {
        _listenerCts?.Cancel();
        try
        {
            _listenerTask?.Wait(TimeSpan.FromSeconds(2));
        }
        catch
        {
            // ignore shutdown race
        }

        _listenerCts?.Dispose();
        _mutex.Dispose();
    }
}
