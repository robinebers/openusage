# Start at login setting

## Goal
Add a settings toggle to control whether OpenUsage launches at OS login.

## Scope
- Add `Start at login` option in settings UI.
- Persist preference in `settings.json` via existing store layer.
- Sync persisted preference with OS autostart through Tauri `autostart` plugin.
- Add/adjust tests for store logic, settings page, and app integration.

## Non-goals
- Custom platform-specific launch arguments.
- New onboarding or migration UI.

## Behavior
- Default: disabled (`false`).
- On app load:
  - Read persisted preference.
  - In Tauri runtime, sync OS autostart state to persisted preference.
- On toggle:
  - Persist updated preference.
  - Apply OS autostart enable/disable in Tauri runtime.
- Failures are logged to console and do not crash the app.
