# Design Choices

This document records opinionated defaults chosen during development.

## 2026-02-07

### Zen Plugin: No Billing API Available

**Context:** The OpenCode Zen provider plugin needs to display usage/billing data.

**Finding:** After analyzing the OpenCode source code (`packages/console/`), the billing data is only exposed via SolidStart SSR routes (`"use server"`) which require web session authentication (cookies), not API key authentication.

**Decision:** The Zen plugin currently:
1. Validates API key by calling `GET /zen/v1/models`
2. Shows "Connected" status with model count
3. Directs users to `opencode.ai/billing` for usage data

**Alternative considered:** Scraping the web console - rejected as fragile and potentially against ToS.

**Next step:** Request a public usage API from OpenCode team via GitHub Discussions.

**Technical details:**
- Balance stored in micro-cents (`/ 100_000_000` for dollars)
- Key fields: `balance`, `monthlyUsage`, `monthlyLimit`, `reload`, `reloadAmount`, `reloadTrigger`
- Source: `packages/console/app/src/routes/workspace/common.tsx:93-120`

## 2026-02-09

### Persist Arrow Offset in AppState

**Context:** The frontend sometimes misses the `window:positioned` event and falls back to centered arrow placement.

**Decision:** Persist `last_arrow_offset` alongside `last_taskbar_position` in `AppState`, so `get_arrow_offset` can restore the correct tray arrow alignment on focus.

### Arrow Offset Accounts for Panel Padding

**Context:** Arrow offset is computed from window left edge, but the arrow is rendered inside a container with horizontal padding (`px-4`).

**Decision:** Subtract 16px container padding when applying `marginLeft` so the arrow tip aligns with the clicked tray icon.

### Side Taskbar Arrow Uses Y Offset

**Context:** When the Windows taskbar is on the left or right, the arrow should align using Y offset and render from the side.

**Decision:** Compute arrow offset using icon center Y for left/right taskbars, and render side arrows with `marginTop` adjusted by vertical padding.

### Use Work Area For Side Positioning

**Context:** On Windows with side taskbars, using full monitor bounds causes the panel to overlap the taskbar.

**Decision:** Use `monitor.work_area()` bounds for left/right window X positioning and clamping so the panel sits fully in the available work area.

### Windows Plugin Paths: Use Common AppData Candidates

**Context:** There is no authoritative published path for Codex/Claude auth files or Cursor/Windsurf `state.vscdb` on Windows.

**Decision:** Probe common Windows locations based on `APPDATA`, `LOCALAPPDATA`, and `USERPROFILE` (e.g., `APPDATA\Cursor\User\globalStorage\state.vscdb`, `USERPROFILE\.claude\.credentials.json`, `APPDATA\codex\auth.json`) and use the first existing path; otherwise fall back to the first candidate.

### Keychain Guard On Windows

**Context:** The host keychain API is only supported on macOS and throws on Windows.

**Decision:** Only call keychain APIs when `ctx.app.platform === "macos"`; use file-based auth paths otherwise.

### OS Gating For Windows Testers

**Context:** We need Windows testers to run plugins while we validate paths and auth locations.

**Decision:** Add `os` to plugin manifests and enable Windows for all user-facing plugins so testers can validate behavior; keep errors explicit when paths are missing.

### Windows Error Messages Include Expected Paths

**Context:** Testers need actionable path hints when auth/state files cannot be found.

**Decision:** Provide Windows-specific error strings that mention likely file locations (AppData/UserProfile) and ask testers to report actual paths.
