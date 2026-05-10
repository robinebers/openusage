using Microsoft.UI.Xaml;

namespace UsageMeter.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) => LogCrash(args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => LogCrash(args.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, args) => LogCrash(args.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var window = new MainWindow();
        _window = window;
        _window.Activate();
    }

    private static void LogCrash(Exception? exception)
    {
        if (exception is null)
        {
            return;
        }

        var logDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "UsageMeter",
            "logs");
        Directory.CreateDirectory(logDirectory);
        File.AppendAllText(
            Path.Combine(logDirectory, "crash.log"),
            $"[{DateTimeOffset.Now:u}]{Environment.NewLine}{exception}{Environment.NewLine}{Environment.NewLine}");
    }
}
