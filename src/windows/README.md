# Usage Meter for Windows

Native Windows implementation of OpenUsage built with C#, WinUI 3, and the Windows App SDK.

## Projects

- `UsageMeter.App` - WinUI 3 desktop shell with a system tray icon.
- `UsageMeter.Core` - provider discovery, auth-file loading, HTTP calls, SQLite reads, and cache persistence.
- `UsageMeter.Tests` - focused unit coverage for path handling and usage model behavior.

## Build and Run

```powershell
dotnet build .\UsageMeter.Windows.slnx
dotnet test .\UsageMeter.Tests\UsageMeter.Tests.csproj
dotnet run --project .\UsageMeter.App\UsageMeter.App.csproj
```

The app currently runs unpackaged with `WindowsPackageType=None`. This follows the Windows App SDK unpackaged app path and avoids depending on Visual Studio's WinUI packaged template during CLI development.

## Providers

The Windows port reads the same account sources as the macOS app where the underlying tool exposes them on Windows:

- Codex: `CODEX_HOME` or `~/.codex/auth.json`
- Claude: `CLAUDE_CODE_OAUTH_TOKEN` or `~/.claude/.credentials.json`
- Cursor: `%APPDATA%\Cursor\User\globalStorage\state.vscdb`
- GitHub Copilot: `gh auth token`
- Gemini: `~/.gemini\oauth_creds.json`
- OpenCode Go: `~/.local\share\opencode`
- Windsurf: `%APPDATA%\Windsurf\User\globalStorage\state.vscdb`

Usage snapshots are cached in `%LOCALAPPDATA%\UsageMeter\usage-cache.json`.
