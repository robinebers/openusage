# Phase 4 Findings — System Integration & Diagnostics (Candidate A spike)

Status: **COMPLETE (shell build verified)** — single-instance, autostart, toasts, sidecar supervision, and shell logging implemented on the Windows machine.
Date: 2026-07-10

Machine: `win32` developer box, Swift 6.3.3 `x86_64-unknown-windows-msvc`, .NET SDK 8.0, VS 2022 Build Tools 17.14.

---

## Executive summary

Phase 4 adds **system-integration seams** on top of the Phase 3 WPF shell + Swift sidecar spike:

| Feature | Status |
|---|---|
| Single instance (named mutex + activation pipe) | **Implemented** |
| Launch at login (HKCU Run + settings JSON) | **Implemented** (off by default) |
| Toast notifications (CommunityToolkit desktop compat) | **Implemented** + quota ≥90% one-shot stub |
| Sidecar lifecycle supervision (restart/backoff, kill on quit) | **Implemented** |
| Shell logging (`shell.log`, token redaction) | **Implemented** |
| Sidecar/core logging (`OpenUsage.log` via `WellKnownPaths.localAppData`) | **Verified path + bootstrap on startup** |
| Unhandled-exception → `shell.log` | **Implemented** |
| Local HTTP API `127.0.0.1:6736` | **Deferred** (documented below) |
| PostHog / minidump / Authenticode | **Out of scope** (Phase 4/5) |

WPF shell: **`dotnet build` succeeded** (net8.0-windows10.0.19041.0).

Core spike tests: **287/287 passing** (3 skipped), 0 failures — verified after sidecar `AppLog.bootstrap()` change.

---

## Build status

| Component | Path | Result |
|---|---|---|
| WPF shell | `spikes/windows-shell/bin/Debug/net8.0-windows10.0.19041.0/OpenUsageShell.dll` | **Build succeeded** |
| Swift sidecar | `spikes/windows-core/.build/x86_64-unknown-windows-msvc/debug/sidecar.exe` | Rebuild with `swift build --product sidecar` |
| Swift tests | `spikes/windows-core` (`swift test`) | **287/287 pass** (3 skipped) |

```powershell
$env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT","User")
$swiftBin = "$env:LOCALAPPDATA\Programs\Swift\Toolchains\6.3.3+Asserts\usr\bin"
$runtimeBin = "$env:LOCALAPPDATA\Programs\Swift\Runtimes\6.3.3\usr\bin"
$env:Path = "$swiftBin;$runtimeBin;" + $env:Path
cd spikes\windows-core
cmd /s /c "`"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat`" && swift build --product sidecar && swift test"
```

```powershell
cd spikes\windows-shell
& "C:\Program Files\dotnet\dotnet.exe" build
& "C:\Program Files\dotnet\dotnet.exe" run
```

---

## 1. Single instance

**Mechanism:** `Local\OpenUsageShell` named mutex (per-user session scope via `Local\` prefix).

- **Primary instance:** acquires mutex, starts activation pipe server `\\.\pipe\OpenUsageShell-<username>`.
- **Second launch:** mutex already held → connects to activation pipe, sends `show\n`, exits immediately (no duplicate tray icon or sidecar).
- **Primary response:** shows/brings flyout to front.

**Code:** `SingleInstanceManager.cs`

### Manual verification

1. Run `dotnet run` from `spikes/windows-shell` — tray icon appears, one `OpenUsageShell` + one `sidecar` in Task Manager.
2. Run `dotnet run` again (second terminal) — second process exits within ~2s; first instance flyout opens.
3. Check `%LOCALAPPDATA%\OpenUsage\logs\shell.log` for `single-instance` lines (`Primary instance…` / `Another instance is running…`).

---

## 2. Launch at login

**Mechanism:** Unpackaged model — `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\OpenUsage` → quoted path to `OpenUsageShell.exe`.

**Settings:** `%LOCALAPPDATA%\OpenUsage\settings.json`

```json
{
  "launchAtLogin": false,
  "quotaToastDedupeKeys": []
}
```

**UI:** Right-click tray → **Launch at Login** (checkable); flyout **Launch at login** checkbox (same state).

**Default:** `launchAtLogin` is **false** — not enabled automatically in tests or first run.

**Code:** `AutoStartManager.cs`, `ShellSettings.cs`

### Manual verification

1. Right-click tray → enable **Launch at Login**.
2. Confirm registry: `reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v OpenUsage`
3. Confirm `settings.json` has `"launchAtLogin": true`.
4. Disable toggle → registry value removed, `"launchAtLogin": false` in JSON.
5. Sign out/in (optional) — shell should start at login when enabled.

---

## 3. Toast notifications

**Library:** `CommunityToolkit.WinUI.Notifications` 7.1.2 (desktop compat, no MSIX required).

**Triggers:**

- Right-click tray → **Test Notification** — always available for manual test.
- **Quota stub:** after snapshot refresh, any `progress` metric ≥90% fires a one-shot toast; dedupe key `providerId:label` persisted in `settings.json` → `quotaToastDedupeKeys`.

Full `QuotaNotificationEvaluator` + pace logic parity is **stubbed** — only the ≥90% progress threshold is implemented.

**Code:** `ToastService.cs`, `QuotaToastEvaluator.cs`

### Manual verification

1. Right-click tray → **Test Notification** — Windows toast appears (Action Center on Win11).
2. With live data showing e.g. Codex Session 100%, refresh — quota toast may fire once; second refresh should not repeat (dedupe).
3. Clear dedupe: edit `settings.json`, remove keys from `quotaToastDedupeKeys`, save, refresh again.

**Note:** First toast on an unpackaged app may require Focus Assist off and notifications enabled for OpenUsage in Settings → System → Notifications.

---

## 4. Sidecar lifecycle supervision

**Mechanism:** `SidecarSupervisor` replaces the Phase 3 `SidecarProcessLauncher`.

| Event | Behavior |
|---|---|
| Shell startup | Launch `sidecar.exe` (auto-discover or `OPENUSAGE_SIDECAR`) |
| Unexpected exit | Log + exponential backoff restart (1s → 2s → 4s → 8s → cap 30s) |
| Pipe disconnect | Shell reconnect loop (unchanged from Phase 3) |
| Quit | `Kill(entireProcessTree: true)` on sidecar |
| Single instance | Only one shell → only one supervised sidecar |

**Code:** `SidecarSupervisor.cs`

### Manual verification

1. Start shell — `shell.log` shows `sidecar Started pid=…`.
2. Task Manager → end `sidecar.exe` — shell restarts it after backoff; log shows `Process exited` + `Scheduling restart`.
3. Quit from tray — both `OpenUsageShell` and `sidecar` exit; log shows `Stopping pid=…`.

---

## 5. Logging

| Log | Path | Writer |
|---|---|---|
| Shell | `%LOCALAPPDATA%\OpenUsage\logs\shell.log` | `ShellLogger` (JWT / api-key / Bearer redaction) |
| Core / sidecar | `%LOCALAPPDATA%\OpenUsage\logs\OpenUsage.log` | `AppLog` → `LogFile` via `WellKnownPaths.localAppData` |

Sidecar now calls `AppLog.bootstrap()` on startup (Phase 4 addition).

**No secrets in logs** — shell uses `ShellLogRedaction`; core uses portable `LogRedaction`.

### Manual verification

1. Run shell → confirm both log files exist under `%LOCALAPPDATA%\OpenUsage\logs\`.
2. Trigger Test Notification / sidecar restart — new lines append to `shell.log`.
3. Grep logs for `sk-`, `Bearer`, `eyJ` — should be redacted or absent.

---

## 6. Crash / resilience (spike scope)

**Implemented:**

- `AppDomain.UnhandledException`, `DispatcherUnhandledException`, `TaskScheduler.UnobservedTaskException` → `shell.log` (`[crash]` tag).

**Documented gaps (not implemented):**

| Gap | Notes |
|---|---|
| Sleep / resume | Sidecar pipe may stall; shell reconnect timer helps but no explicit power-event handling |
| Explorer restart | `TaskbarCreated` tray re-registration still deferred (Phase 3) |
| Session lock/unlock | No dedicated handler |
| Network change | Reconnect loop only |
| PostHog telemetry | Phase 4/5 |
| Native minidump / PDB upload | Phase 4/5 |
| Authenticode-verified crash test | Phase 5 |

---

## 7. Local HTTP API (stretch — deferred)

`GET http://127.0.0.1:6736/v1/usage` mirroring macOS `LocalUsageAPI` was **not implemented** in this spike to avoid destabilizing the sidecar event loop. Recommended Phase 5 approach:

- Add loopback HTTP listener in sidecar (or shared core module) serving cached snapshot JSON.
- Reuse `SidecarService.snapshotDTOs()` wire shape; tighten CORS same as macOS decision.
- Verify no Windows Firewall prompt on loopback.

---

## Paths created / modified

### C# (`spikes/windows-shell/`)

| File | Purpose |
|---|---|
| `SingleInstanceManager.cs` | Mutex + activation pipe |
| `ShellSettings.cs` | JSON persistence |
| `AutoStartManager.cs` | HKCU Run registry |
| `ShellLogger.cs` / `ShellLogRedaction.cs` / `ShellPaths.cs` | Logging |
| `SidecarSupervisor.cs` | Process supervision |
| `ToastService.cs` | Desktop toasts |
| `QuotaToastEvaluator.cs` | ≥90% progress stub |
| `App.xaml.cs` | Integration + crash handlers |
| `FlyoutWindow.*` | Launch-at-login checkbox |
| `OpenUsageShell.csproj` | TFM `net8.0-windows10.0.19041.0`, CommunityToolkit package |

### Swift (`spikes/windows-core/`)

| File | Change |
|---|---|
| `Sources/sidecar/NamedPipeServer.swift` | `AppLog.bootstrap()` on sidecar startup |

---

## Remaining Phase 4 / 5 gaps

- Local HTTP API on port 6736
- System-proxy discovery (`docs/proxy.md` — config-file proxy only today)
- PostHog HTTP telemetry + opt-out UI
- Full `QuotaNotificationEvaluator` + pace notification logic
- Toast activation → open specific settings screen
- `TaskbarCreated` / Explorer restart tray recovery
- Sleep/resume explicit handling
- Authenticode signing + updater integrity
- `script/build_and_run.ps1` dev loop
- Global hotkey, full settings UI, accessibility pass (Phase 3 carryover)

---

## Heads-up

- **Quota toasts** dedupe permanently per `provider:label` until keys cleared in settings — production will need time-bucket or reset-aware logic.
- **Launch at login** uses the current `OpenUsageShell.exe` path; moving the binary requires re-toggling autostart.
- **Toasts** on unpackaged WPF may need a Start Menu shortcut with AUMID for reliable branding in a production installer (Phase 5 packaging).
