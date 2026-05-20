# Antigravity IDE

> Antigravity IDE is the standalone 2.0 version of [Antigravity](antigravity.md). Shares the same Codeium language server binary and Connect-RPC protocol.

## Overview

- **Vendor:** Google
- **Protocol:** Connect RPC v1 (JSON over HTTP) on local language server
- **Service:** `exa.language_server_pb.LanguageServerService`
- **Auth:** CSRF token from process args
- **Quota:** fraction (0.0–1.0, where 1.0 = 100% remaining)
- **Quota window:** 5 hours
- **Requires:** Antigravity IDE running (language server process)

## Differences from Antigravity

| | Antigravity | Antigravity IDE |
|---|---|---|
| App bundle | `Antigravity.app` | `Antigravity IDE.app` |
| LS marker (`--app_data_dir`) | `antigravity` | `antigravity-ide` |
| State DB path | `~/Library/Application Support/Antigravity/...` | `~/Library/Application Support/Antigravity IDE/...` |
| OAuth in SQLite | ✅ `antigravityUnifiedStateSync.oauthToken` | ❌ Not present |
| Cloud Code API fallback | ✅ | ❌ (no OAuth tokens) |

## Discovery

Same as [Antigravity](antigravity.md#discovery), but with marker `antigravity-ide`:

```bash
# Find process
ps -ax -o pid=,command= | grep 'language_server_macos.*antigravity-ide'
# Match: --app_data_dir antigravity-ide
```

## Endpoints

Identical to [Antigravity](antigravity.md#endpoints) — same LS binary, same RPC service:

- `GetUserStatus` (primary)
- `GetCommandModelConfigs` (fallback)

Metadata uses `ideName: "antigravity-ide"` and `extensionName: "antigravity-ide"`.

## Plugin Strategy

1. Discover LS process via `ctx.host.ls.discover()` with marker `antigravity-ide`
2. Probe ports with `GetUnleashData` to find the Connect-RPC endpoint
3. Call `GetUserStatus` for plan name + per-model quota
4. Fall back to `GetCommandModelConfigs` if `GetUserStatus` fails
5. If LS not found or all calls fail: error "Start Antigravity IDE and try again."

No Cloud Code API fallback — Antigravity IDE's SQLite does not contain OAuth tokens.
