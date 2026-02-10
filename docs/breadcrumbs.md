# Breadcrumbs

## 2026-02-09

- Windows dev: align AppState plugin/probe types with LoadedPlugin + PluginOutput, and persist arrow offset for tray alignment fallback.
- Arrow alignment: account for panel horizontal padding when positioning tray arrow.
- Side taskbar: compute arrow offset on Y axis and render left/right arrows.
- Side taskbar: use work area bounds to avoid overlapping the taskbar.
- Windows plugin scan: identified OS path/keychain blockers per plugin.
- Windows plugins: add Windows path candidates for Codex/Claude/Cursor/Windsurf and guard keychain usage to macOS.
- Windows OS gating: enable windows in plugin manifests and add actionable missing-path errors for testers.
- Cleanup: moved `WINDOWS_CHANGES.md` and reserved `nul` file to trash; kept `src/contexts/taskbar-context.tsx` for later wiring.
- Windows updater: documented that production updates require Authenticode signing; marked current state as test-only.
- Windows signing: added conditional PFX import step and owner follow-up checklist.
- Cleanup: removed unused `src/contexts/taskbar-context.tsx`.
- PR 77 fixes: re-enabled tray icon updates, restored Linux tray click handling, guarded window clamp, and replaced env-based Windows probes with `~`-based paths under a CODEX_HOME-only allowlist.

## 2026-02-10

- Verified sqlite access uses external `sqlite3` CLI in `src-tauri/src/plugin_engine/host_api.rs` and no bundled sqlite binary/resources in `src-tauri/tauri.conf.json`.
- Switched plugin host sqlite to embedded `rusqlite` with bundled SQLite for cross-platform availability.
- Replaced Windows process discovery `wmic` with PowerShell CIM JSON parsing in `src-tauri/src/plugin_engine/host_api.rs`.
- Added Windows DPAPI-backed `host.vault` and updated Copilot auth to use it.
- Enforced Windows signing secrets in publish workflow to prevent unsigned releases.
