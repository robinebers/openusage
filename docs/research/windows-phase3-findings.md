# Phase 3 Findings — Windows UI Shell (Candidate A spike)

Status: **COMPLETE on Windows machine** — sidecar IPC + WPF tray shell built and verified with live Claude/Codex/Cursor data.
Date: 2026-07-10

Machine: `win32` developer box, Swift 6.3.3 `x86_64-unknown-windows-msvc`, .NET SDK 8.0.422, VS 2022 Build Tools 17.14.

---

## Executive summary

Phase 3 delivered an executable spike of **candidate A** (C# WPF shell + Swift core sidecar over user-restricted named-pipe JSON IPC). The Swift `sidecar` executable reuses Phase 2 provider runtimes; the WPF shell shows a tray icon, borderless flyout, and right-click menu. **Live provider data** for Claude, Codex, and Cursor renders correctly through the pipe.

> **Superseded UX:** Later polish added a floating always-on-top strip and brand tray icon; Widgets Board / taskbar-pill experiments were removed. See [windows-phase6-findings.md](windows-phase6-findings.md) and [windows.md](../windows.md).

Core spike tests: **287/287 passing** (3 skipped), 0 failures — up from 282/282 in Phase 2 (+5 SidecarIPC tests).

---

## Build status

| Component | Path | Result |
|---|---|---|
| Swift sidecar | `spikes/windows-core/.build/x86_64-unknown-windows-msvc/debug/sidecar.exe` | **Build complete** |
| Swift tests | `spikes/windows-core` (`swift test`) | **287/287 pass** (3 skipped) |
| WPF shell | `spikes/windows-shell/bin/Debug/net8.0-windows/OpenUsageShell.dll` | **Build succeeded** |
| WPF run | `dotnet run` from `spikes/windows-shell` | **Tray process started** (`OpenUsageShell` + child `sidecar`) |

Swift build requires `vcvars64` + `SDKROOT` (unchanged from Phase 0–2). .NET 8 SDK was installed via winget for this phase.

---

## IPC verification

Pipe: `\\.\pipe\OpenUsageCore-<username>` with DACL (current user SID + SYSTEM) via `ou_pipe_create_user_restricted`.

Smoke script: `spikes/windows-shell/scripts/smoke-sidecar.ps1`

```
PONG: {"op":"pong","version":1}
```

### Live snapshot (redacted metric lines)

Full JSON logged at `docs/research/windows-phase3-snapshot-log.json`.

| Provider | Plan | Status | Sample metric lines |
|---|---|---|---|
| **Claude** | Max 5x | ok | Session: 56%; Weekly: 27%; Fable: 50%; Today: $57.66, 32.9M tokens; Last 30 Days: $2.7K, 2.7B tokens |
| **Codex** | Plus | ok | Session: 100%; Weekly: 28%; Rate Limit Resets: 1 available; Today: $19.32, 21M tokens; Last 30 Days: $444.08, 431.5M tokens |
| **Cursor** | Pro | ok | Total usage: 48%; Auto usage: 34%; API usage: 93%; Today: $52.00, 33.4M tokens; Last 30 Days: $334.37, 329.5M tokens |
| Grok | — | no_credentials | (no local auth) |
| OpenRouter | — | no_credentials | (no API key) |
| Z.ai | — | no_credentials | (no API key) |

No secret tokens appear in pipe JSON (verified by protocol design + spot-check of logged snapshot).

---

## Tray + flyout behavior (observed)

| Behavior | Notes |
|---|---|
| Tray icon | `System.Windows.Forms.NotifyIcon` with `SystemIcons.Application` placeholder (no custom .ico yet) |
| Left-click | Opens borderless flyout (`WindowStyle=None`, `Topmost`, no taskbar entry) |
| Right-click | Context menu: Refresh, Settings (stub message), Quit |
| Dismiss | Escape or window deactivation (outside click) hides flyout |
| Position | Work-area bottom-right fallback — `Shell_NotifyIconGetRect` **not** implemented |
| Theme | Light/dark follows `HKCU\...\Themes\Personalize\AppsUseLightTheme` registry value |
| Sidecar lifecycle | Shell launches `sidecar.exe` on startup; reconnect loop on pipe failure |
| Keyboard | Escape dismisses flyout; flyout Refresh button wired; no global hotkey |
| DPI | Standard WPF per-monitor DPI — no explicit 100–300% pass |

**Tray + flyout with live data:** confirmed via IPC smoke test and running `OpenUsageShell` (sidecar child process observed). Screenshot not captured in this automated run; metric evidence is in the snapshot log above.

---

## Paths created

### Swift (`spikes/windows-core/`)

- `Sources/Win32Shim/ou_namedpipe.c` — user-restricted named pipe C shim
- `Sources/OpenUsageCore/Services/SidecarIPC.swift` — JSON protocol + snapshot mapper
- `Sources/OpenUsageCore/Services/SidecarService.swift` — provider registry / command handler
- `Sources/sidecar/NamedPipeServer.swift` — pipe server + `@main` entry
- `Tests/OpenUsageCoreTests/SidecarIPCTests.swift` — 5 codec/mapper tests
- `Package.swift` — `sidecar` executable product

### C# (`spikes/windows-shell/`)

- `OpenUsageShell.csproj` — WPF + WinForms NotifyIcon
- `App.xaml` / `App.xaml.cs` — tray controller, theme, context menu
- `FlyoutWindow.xaml` / `FlyoutWindow.xaml.cs` — provider cards UI
- `SidecarClient.cs` — pipe client + sidecar process launcher
- `PROTOCOL.md`, `README.md`
- `scripts/smoke-sidecar.ps1` — headless IPC verification

### Docs

- `docs/research/windows-phase3-findings.md` (this file)
- `docs/research/windows-phase3-snapshot-log.json` — redacted live snapshot

---

## Deferred / remaining Phase 3 gaps

| Item | Status |
|---|---|
| Full dashboard / customize / settings screens | Deferred — spike shows provider cards only |
| Pinned tray metrics design | Deferred |
| `Shell_NotifyIconGetRect` flyout anchoring | Deferred (work-area fallback) |
| `TaskbarCreated` tray re-registration | Deferred |
| Mica/Acrylic materials | Deferred |
| Share card image rendering | Deferred |
| Global hotkey (`RegisterHotKey`) | Deferred |
| Accessibility pass (Narrator/UIA, High Contrast) | Deferred |
| Custom OpenUsage tray icon (.ico, high-DPI) | Placeholder system icon |
| Panel height morphing (`PanelHeightController`) | Deferred |
| Sidecar coordinated update / single-instance mutex | Phase 4 |
| WinUI 3 / unpackaged packaging identity | Phase 0 owner decision still pending |

---

## Heads-up

- Sidecar `bootstrap()` runs a full `refresh` for all providers with credentials on startup — first connect can take **30–60s** while Claude/Codex/Cursor hit live APIs (same as e2e-harness cost).
- WPF + WinForms hybrid requires disambiguating `Application`, `Color`, `KeyEventArgs` types (resolved with aliases / fully qualified names).
- Pipe ACL uses current-user SID + SYSTEM; no anonymous access. Fallback to default security descriptor if DACL build fails (not observed on this machine).
