# OpenUsage Windows Shell (research spike)

WPF tray + floating strip + flyout for candidate **A** (C# shell + Swift sidecar over a private named pipe).

Live UX (current):

- **Floating strip** — always-on-top, draggable, remembers position; macOS menu-bar-style provider glyphs + stacked `% left`
- **Tray icon** — OpenUsage brand mark; left-click opens flyout; right-click context menu
- **Flyout** — dark provider cards with progress bars (Left / remaining), spend rows, Refresh, Launch at Login
- **Periodic refresh** — every 5 minutes (same cadence as macOS), plus manual Refresh
- **System** — single-instance, toasts (branded **OpenUsage** name + icon via Start Menu AUMID shortcut), logging, sidecar supervision (kills orphan `sidecar.exe` on launch)

Research notes: `docs/windows.md`, `docs/research/windows-phase6-findings.md`.

## Prerequisites

- .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`)
- Swift 6.3+ Windows toolchain with VS Build Tools (`docs/research/windows-toolchain.md`)
- Provider credentials on the machine (Claude/Codex/Cursor for live data)

## One-command dev loop

From the repo root (sets up Swift/MSVC, builds sidecar + shell, launches):

```powershell
.\script\build_and_run.ps1          # build and run
.\script\build_and_run.ps1 verify   # build, run, fail if process missing
```

## Manual build

### 1. Swift sidecar

```powershell
$env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT","User")
cd spikes\windows-core
cmd /s /c "`"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat`" && swift build --product sidecar && swift test"
```

Sidecar: `spikes\windows-core\.build\x86_64-unknown-windows-msvc\debug\sidecar.exe`  
Optional: `OPENUSAGE_SIDECAR` = full path if auto-discovery fails.

### 2. WPF shell

```powershell
cd spikes\windows-shell
dotnet build
dotnet run
```

## Interactions

- **Drag** the floating strip; position is saved under `%LOCALAPPDATA%\OpenUsage\settings.json`
- **Click** or **double-click** the strip → flyout (opens / focuses; does not toggle closed)
- **Click** the tray icon → toggles flyout
- **Right-click** tray / strip → Refresh / Launch at Login / Test Notification / Quit
- **Second launch** → activates existing instance and exits
- **Escape** or click outside → dismisses flyout

Logs: `%LOCALAPPDATA%\OpenUsage\logs\shell.log` (shell), `OpenUsage.log` (sidecar).

## Protocol

See [PROTOCOL.md](./PROTOCOL.md).

## Deferred (not in this spike)

- Full dashboard / customize / settings screens
- Local HTTP API on `127.0.0.1:6736`
- Reset countdowns in the flyout (`resetsAt` not yet on the wire)
- Mica/Acrylic, share cards, global hotkey
- `TaskbarCreated` tray re-registration
- PostHog, minidump, Authenticode signing
- Accessibility pass (Narrator/UIA)
