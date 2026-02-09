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
