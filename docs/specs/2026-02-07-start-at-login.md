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
  - In web runtime, persist updated preference directly.
  - In Tauri runtime, apply OS autostart enable/disable first, then persist confirmed OS state from `isEnabled()`.
  - If Tauri autostart command fails, rollback UI + persisted preference to prior value.
- Failures are logged to console and do not crash the app.
