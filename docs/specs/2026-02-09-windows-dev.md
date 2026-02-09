# Windows Dev Fixes (2026-02-09)

## Goals

- Fix Windows dev build errors in `src-tauri` caused by mismatched plugin state types.
- Ensure tray arrow can align to icon even if `window:positioned` event is missed.

## Non-Goals

- No new UI behavior changes beyond arrow offset alignment.
- No plugin runtime changes.

## Changes

- Store `LoadedPlugin` in `AppState` and store probe results as `PluginOutput`.
- Persist `last_arrow_offset` in window positioning so `get_arrow_offset` is reliable.
- Use Y-axis arrow offsets and side arrows for left/right taskbars.
- Use work area bounds for side-taskbar window positioning/clamping.
