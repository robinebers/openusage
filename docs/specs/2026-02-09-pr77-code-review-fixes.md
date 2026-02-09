2026-02-09

# PR 77 code review fixes

## Goal
- Validate reported regressions and apply minimal fixes.

## Issues
- Tray icon updates are no-op in frontend.
- Linux tray click no longer shows/hides window.
- Window position clamp can panic if window exceeds work area.
- Env allowlist exceeds stated minimal exposure (CODEX_HOME only).
- Claude plugin helper scopes cause ReferenceError.
- Windsurf plugin helper scopes leak to global.

## Plan
- Re-enable tray icon updates via `renderTrayBarsIcon` and `TrayIcon.setIcon`.
- Restore Linux tray click handling to match Windows show/hide behavior.
- Guard clamp bounds when window size exceeds work area.
- Restrict env allowlist to `CODEX_HOME` and adjust plugin helpers accordingly.
- Move helper functions inside plugin IIFEs to restore correct scope.

## Testing
- Not run (manual reasoning + compilation expected).
