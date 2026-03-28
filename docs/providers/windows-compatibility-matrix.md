# Windows Provider Compatibility Matrix

This is the source of truth for Windows provider scope in `UsageTray`.

## First support wave

- Claude
- Codex
- Cursor

These are the only providers that are in scope for the first Windows release. Everything else is either planned for a later wave, explicitly deferred, or blocked behind macOS-specific storage assumptions.

## Matrix

| Provider | Windows status | Detection strategy | Expected dependencies | Notes |
|---|---|---|---|---|
| Claude | v1 wave | `~/.claude/.credentials.json` | Claude Code local login, optional `ccusage` | Windows keychain fallback is out of v1 scope. |
| Codex | v1 wave | `%CODEX_HOME%/auth.json`, `%APPDATA%/codex/auth.json`, `%LOCALAPPDATA%/codex/auth.json`, `~/.codex/auth.json` | Codex local login, optional `ccusage` | File-based auth is the supported Windows path in v1. |
| Cursor | v1 wave | `%APPDATA%/Cursor/User/globalStorage/state.vscdb` | Cursor desktop app signed in, `sqlite3` | Real Windows path confirmed in development. |
| JetBrains AI Assistant | planned | `~/AppData/Roaming/JetBrains` | JetBrains IDE local data | Already has Windows-aware path logic; deferred until first wave is stable. |
| Copilot | planned | GitHub CLI / credential-manager backed auth | GitHub CLI auth or Windows credential bridge | Depends on Windows credential handling work. |
| Factory | planned | `~/.factory/auth.encrypted`, `~/.factory/auth.json` | Factory CLI auth | Looks portable enough, but out of v1 scope. |
| Kimi | planned | `~/.kimi/credentials/kimi-code.json` | Kimi CLI auth | Out of v1 scope. |
| Minimax | planned | `MINIMAX_*` environment variables | Windows env vars | Likely low-effort later. |
| Z.ai | planned | `ZAI_API_KEY` or `GLM_API_KEY` | Windows env vars | Likely low-effort later. |
| Amp | deferred | `~/.local/share/amp/secrets.json` | Amp CLI local data | Unix-only local data layout today. |
| Gemini | deferred | `~/.gemini/*` and Unix global package locations | Gemini CLI auth, provider-specific OAuth helper discovery | Needs Windows-specific install-path discovery. |
| OpenCode Go | deferred | `~/.local/share/opencode/*` | OpenCode Go local data, `sqlite3` | Unix local-share layout today. |
| Antigravity | blocked | `~/Library/Application Support/Antigravity/...` | Antigravity desktop app, `sqlite3` | Hard macOS storage assumption. |
| Perplexity | blocked | `~/Library/.../Cache.db` | Perplexity desktop app, `sqlite3` | Hard macOS cache-path assumption. |
| Windsurf | blocked | `~/Library/Application Support/Windsurf/...` | Windsurf desktop app, `sqlite3` | Hard macOS storage assumption. |

## Status meanings

- `v1 wave`: committed for the first Windows release.
- `planned`: expected to be portable enough later, but intentionally outside the first release scope.
- `deferred`: technically possible later, but the current implementation assumes Unix-style local storage.
- `blocked`: currently tied to macOS-only storage or shell behavior and not supportable on Windows without a rewrite.
