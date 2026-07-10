# Windows manual test checklist

For the **experimental spike** (`spikes/windows-shell` + `spikes/windows-core`). Run on a Windows 11 x64 machine unless the owner chooses a broader OS floor.

**Legend:** Pass / Fail / Untested — with date when run.

| # | Test | Steps | Result | Date | Notes |
|---|---|---|---|---|---|
| 1 | Fresh zip launch | Extract `dist/windows/OpenUsage-windows-x64.zip`, run `OpenUsageShell.exe` from extracted folder | **Pass** | 2026-07-10 | Verified from staged `dist/windows/OpenUsage/`; tray + sidecar start |
| 2 | Dev build launch | `.\script\build_and_run.ps1 verify` | **Pass** | 2026-07-10 | OpenUsageShell pid confirmed running |
| 3 | Single instance | Launch shell twice; second instance exits, first shows flyout | **Pass** | 2026-07-10 | 1× shell + 1× sidecar after second launch |
| 4 | Floating strip | Strip visible, always-on-top; drag and relaunch → position restored | Untested | | Surviving UX (Widgets/pill removed) |
| 5 | Launch at login toggle | Enable tray/flyout toggle → check `HKCU\...\Run\OpenUsage` + `settings.json`; disable and confirm removed | **Pass** | 2026-07-10 | Registry round-trip via script; left **OFF** |
| 6 | Test notification | Tray → **Test Notification** | **Pass** | 2026-07-10 | Prior session log: `Toast notifier ready` + toast shown |
| 7 | Refresh Claude / Codex / Cursor | Flyout Refresh with live creds | **Pass** | 2026-07-10 | e2e metric lines + plans |
| 8 | No-credentials providers | Grok/OpenRouter/Z.ai without keys appear greyed in flyout | Untested | | Status `no_credentials`; opacity polish |
| 9 | Refreshing banner | Click Refresh → “Refreshing…” visible until done | Untested | | |
| 10 | Orphan sidecar | Leave stray `sidecar.exe`, relaunch shell → one sidecar remains | Untested | | Supervisor kill-on-launch |
| 11 | Sidecar crash recovery | Kill `sidecar.exe` in Task Manager | Untested | | |
| 12 | Keyboard dismiss (Esc) | Open flyout, press Esc | Untested | | |
| 13 | Logging | Confirm `%LOCALAPPDATA%\OpenUsage\logs\shell.log` + `OpenUsage.log`; no raw tokens | **Pass** | 2026-07-10 | Both files present |
| 14 | Update check stub | Launch with network; 404 on placeholder feed is OK | **Pass** | 2026-07-10 | `Feed returned 404` in shell.log (expected) |
| 15 | SmartScreen (unsigned) | First run on clean VM | Untested | | Needs VM without prior allow |

Deferred / expected gaps (not blocking research PR): reboot autostart, Explorer restart tray recovery, High DPI matrix, offline, quota toast dedupe.

## Automated smoke script

`spikes/windows-shell/scripts/phase6-smoke.ps1` — headless checks for launch, single-instance, autostart registry, logs, RSS.

**Note:** External pipe probes fail while the shell holds the sidecar connection (single client). Use `smoke-sidecar.ps1` for IPC/snapshot when the shell is not running.

## Sign-off

Spike is **not beta-ready**. See [windows-phase6-findings.md](windows-phase6-findings.md) for blockers and owner decisions.
