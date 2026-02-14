# Windows OS Gating + Error Reporting (2026-02-09)

## Goals

- Declare OS support in plugin manifests so Windows can load targeted plugins.
- Provide clear, actionable error messages for Windows testers when paths are missing.

## Non-Goals

- Prove exact Windows paths for every app.
- Add new runtime APIs or change plugin protocol.

## Plan

- Add `os` to plugin.json for each plugin.
- Improve Windows-specific error messages in Codex, Claude, Cursor, and Windsurf.
- Keep keychain access macOS-only and rely on file-based auth for Windows.

## Notes

- Windows is enabled for all user-facing plugins to allow tester validation.
- Errors include expected Windows file locations and request testers report actual paths.
