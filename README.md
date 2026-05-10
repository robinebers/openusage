# UsageMeter

Windows-native usage meter for AI coding subscriptions.

UsageMeter is a small internal WinUI app. It shows usage for the accounts already signed in on this Windows machine and stays available from the system tray.

## Supported Providers

- Claude
- Codex
- Copilot
- Cursor
- Gemini
- OpenCode Go
- Windsurf

Provider support is native C#. Provider icons are stored in `src/UsageMeter.App/Assets/Providers`.

## Requirements

- Windows 10 1809 or newer
- .NET 11 preview SDK
- Visual Studio or Build Tools with Windows App SDK support

The repo includes `global.json` pinned to the .NET 11 preview SDK used for local validation.

## Build, Test, Run

```powershell
dotnet build .\UsageMeter.Windows.slnx
dotnet test .\tests\UsageMeter.Tests\UsageMeter.Tests.csproj
dotnet run --project .\src\UsageMeter.App\UsageMeter.App.csproj
```

## Release

UsageMeter publishes a Windows-only zip from `dotnet publish`.

```powershell
$version = "0.1.0"
dotnet publish .\src\UsageMeter.App\UsageMeter.App.csproj -c Release -r win-x64 --self-contained true -p:Version=$version -o .\artifacts\publish\UsageMeter-win-x64
Compress-Archive -Path .\artifacts\publish\UsageMeter-win-x64\* -DestinationPath ".\release-assets\windows\UsageMeter-v$version-win-x64.zip" -Force
.\scripts\Publish-GitHubRelease.ps1 -Version $version -AssetsPath .\release-assets\windows
```

WinGet publishing notes are in [docs/release-and-winget.md](docs/release-and-winget.md).

## Data

Usage snapshots are cached in `%LOCALAPPDATA%\UsageMeter\usage-cache.json`.

## License

[MIT](LICENSE)
