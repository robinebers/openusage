# Plugin util + dedup refactor

Date: 2026-02-03

## Goal
- Add `ctx.util` helpers injected by host for shared JSON/HTTP/retry/time logic.
- Refactor claude/codex/cursor plugins to use `ctx.util` helpers.
- Align plugin tests with new ctx surface.
- Dedup frontend plugin display state type, timer logic, settings constants.

## Non-goals
- No plugin bundling.
- No behavior changes beyond refactor/dedup.

## API additions
- `ctx.util.tryParseJson(text)` -> value | null
- `ctx.util.safeJsonParse(text)` -> { ok: true, value } | { ok: false }
- `ctx.util.request(opts)` -> resp
- `ctx.util.requestJson(opts)` -> { resp, json }
- `ctx.util.isAuthStatus(status)` -> boolean
- `ctx.util.retryOnceOnAuth({ request, refresh })` -> resp
- `ctx.util.parseDateMs(value)` -> number | null
- `ctx.util.needsRefreshByExpiry({ nowMs, expiresAtMs, bufferMs })` -> boolean

## Plan
1. Inject `ctx.util` in `src-tauri/src/plugin_engine/host_api.rs`.
2. Refactor claude/codex/cursor plugins to use `ctx.util` helpers.
3. Create `plugins/test-helpers.js`, update plugin tests to use it.
4. Frontend dedup: shared `PluginDisplayState`, `useNowTicker`, settings options constants.
5. Verify: `bun run test`, `bun run build`.
