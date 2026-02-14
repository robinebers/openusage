# Windows Plugin Porting Scan (2026-02-09)

## Goals

- Identify Windows blockers for remaining plugins.
- Outline path normalization or keychain requirements per plugin.

## Non-Goals

- Implement Windows support for each plugin.
- Modify plugin runtime behavior.

## Findings

- antigravity: already Windows-aware for LS process name; no path blockers.
- codex: auth file now checks Windows candidates (`APPDATA`, `LOCALAPPDATA`, `USERPROFILE`) before Unix paths.
- claude: credentials file now checks Windows candidates (`USERPROFILE`, `APPDATA`, `LOCALAPPDATA`) before `~/.claude`.
- copilot: keychain access is now guarded to macOS; Windows relies on `auth.json` fallback.
- cursor: now checks Windows candidates for `globalStorage/state.vscdb` plus Linux/macOS defaults.
- windsurf: now checks Windows candidates for `globalStorage/state.vscdb` plus Linux/macOS defaults; Windows LS process name already handled.
- mock: test-only.

## Next Steps

- Validate actual on-disk paths for Codex/Claude/Cursor/Windsurf on Windows installs.
- Add Windows OS gating in plugin.json if needed and surface user-friendly errors when paths are missing.
