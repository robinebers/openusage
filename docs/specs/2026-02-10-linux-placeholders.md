# Linux Placeholder Enablement

## Goal
- Restore Linux builds and plugin availability after OS gating changes.

## Scope
- Add Linux implementation for tray window positioning.
- Include Linux in supported OS lists for major plugins.
- Update language server discovery to handle Linux process names.
- Allow Copilot to read gh CLI hosts file on Linux.

## Non-Goals
- Guarantee full Linux feature parity.
- Add Linux-specific UI or packaging work.

## Approach
- Provide a Linux `position_window_at_tray` that positions the window using the tray icon location.
- Add `linux` to plugin `os` arrays for Claude, Codex, Cursor, Windsurf, Copilot, Antigravity.
- Treat the Linux LS process name as `language_server_linux_x64` (placeholder).
- Use `~/.config/gh/hosts.yml` for Copilot token on Linux.

## Testing
- `cargo test` (if Linux runner available)
- `bunx vitest run plugins/copilot/plugin.test.js`

## Risks
- LS process name may differ on Linux distributions.
- Some providers may still fail due to upstream app path differences.

## Open Questions
- None.
