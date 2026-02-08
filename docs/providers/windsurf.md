# Windsurf

> Reverse-engineered from app bundle, extension.js, and language server binary. May change without notice.

Windsurf and [Antigravity](antigravity.md) share the same Codeium language server binary and Connect-RPC protocol. The discovery, port probing, and RPC endpoints are virtually identical — the key differences are authentication (Windsurf requires an API key) and the usage model (credits vs fractions).

## Variants

The plugin supports two Windsurf variants, probed in this order:

| Variant | App | Bundle ID | `--ide_name` | App Support dir |
|---|---|---|---|---|
| **Windsurf** | `Windsurf.app` | `com.exafunction.windsurf` | `windsurf` | `~/Library/Application Support/Windsurf/` |
| **Windsurf Next** | `Windsurf - Next.app` | `com.exafunction.windsurfNext` | `windsurf-next` | `~/Library/Application Support/Windsurf - Next/` |

Both use the same Codeium language server binary (`language_server_macos_arm`), same Connect-RPC service, same CSRF auth, and same `GetUserStatus` RPC. They differ only in:

- **Process marker**: `windsurf` vs `windsurf-next` (matched via `--ide_name` exact value)
- **SQLite path**: `Windsurf/User/globalStorage/state.vscdb` vs `Windsurf - Next/User/globalStorage/state.vscdb`
- **ideName in metadata**: `windsurf` vs `windsurf-next`

## Overview

- **Vendor:** Codeium (Windsurf)
- **Protocol:** Connect RPC v1 (JSON over HTTP) on local language server
- **Service:** `exa.language_server_pb.LanguageServerService`
- **Auth:** API key (`sk-ws-01-...`) from SQLite + CSRF token from process args
- **Usage model:** credit-based (prompt + flex credits, stored in hundredths)
- **Billing cycle:** monthly (`planStart` / `planEnd`)
- **Timestamps:** ISO 8601
- **Requires:** Windsurf IDE running (language server is a child process)

## Discovery

Same process as [Antigravity](antigravity.md) — same binary, same flags. The distinguishing marker is the `--ide_name` flag value in the process args.

```bash
# 1. Find process and extract CSRF token + version
ps -ax -o pid=,command= | grep 'language_server_macos'
# Windsurf:      --ide_name windsurf
# Windsurf Next: --ide_name windsurf-next
# Extract: --csrf_token <token>
# Extract: --windsurf_version <version>
# Extract: --extension_server_port <port>  (HTTP fallback)

# 2. Find listening ports
lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>

# 3. Probe each port to find the Connect-RPC endpoint
POST https://127.0.0.1:<port>/.../GetUnleashData  → any response wins

# 4. Get API key from SQLite (path depends on variant)
# Windsurf:
sqlite3 ~/Library/Application\ Support/Windsurf/User/globalStorage/state.vscdb \
  "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus'"
# Windsurf Next:
sqlite3 ~/Library/Application\ Support/Windsurf\ -\ Next/User/globalStorage/state.vscdb \
  "SELECT value FROM ItemTable WHERE key = 'windsurfAuthStatus'"
# → JSON: { apiKey: "sk-ws-01-...", ... }
```

Port and CSRF token change on every IDE restart. The LS may use HTTPS with a self-signed cert.

## Headers (all local requests)

| Header | Required | Value |
|---|---|---|
| Content-Type | yes | `application/json` |
| Connect-Protocol-Version | yes | `1` |
| x-codeium-csrf-token | yes | `<csrf_token>` (from process args) |

## Endpoints

### GetUserStatus (primary)

Returns plan info with credit-based usage for the current billing cycle. Same RPC as [Antigravity](antigravity.md), but requires `metadata.apiKey`.

```
POST http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus
```

#### Request

```json
{
  "metadata": {
    "apiKey": "sk-ws-01-...",
    "ideName": "windsurf",
    "ideVersion": "<version>",
    "extensionName": "windsurf",
    "extensionVersion": "<version>",
    "locale": "en"
  }
}
```

For Windsurf Next, use `"ideName": "windsurf-next"` and `"extensionName": "windsurf-next"`.

Unlike [Antigravity](antigravity.md), Windsurf **requires** `metadata.apiKey`. The LS uses it to authenticate with the cloud backend internally. Antigravity authenticates via the Google OAuth session instead.

#### Response (~167KB, mostly model configs)

```jsonc
{
  "userStatus": {
    "planStatus": {
      "planInfo": {
        "planName": "Teams",                    // "Free" | "Pro" | "Teams" | "Free Trial"
        "monthlyPromptCredits": 50000,
        "monthlyFlexCreditPurchaseAmount": 100000
      },
      "planStart": "2026-01-18T09:07:17Z",
      "planEnd": "2026-02-18T09:07:17Z",
      "availablePromptCredits": 50000,          // total pool (in hundredths)
      "usedPromptCredits": 4700,                // consumed (omitted when 0)
      "availableFlexCredits": 2679300,
      "usedFlexCredits": 175550
    }
  }
}
```

#### Field mapping

| Response field | Display | Notes |
|---|---|---|
| `availablePromptCredits` | Total credit pool | Divide by 100 for display (50000 → 500) |
| `usedPromptCredits` | Credits consumed | Divide by 100 |
| `planStart` / `planEnd` | Billing cycle | ISO 8601, used for pacing |
| negative `available*` | Unlimited | Skip that credit line |

## Differences from Antigravity

| | Windsurf | Antigravity |
|---|---|---|
| **Auth** | API key (`sk-ws-01-`) required in metadata | No API key needed (CSRF only) |
| **Usage model** | Credit-based (prompt + flex) | Fraction-based per model (0.0–1.0) |
| **Credit units** | Stored in hundredths (÷100 for display) | N/A |
| **Billing cycle** | Monthly (`planStart`/`planEnd`) | 5-hour rolling windows per model |
| **Version flag** | `--windsurf_version` | N/A |
| **Token location** | SQLite `windsurfAuthStatus` → `apiKey` | Not needed |
| **Models shown** | Not used (credits are the metric) | Per-model quota bars |

Both use the same Codeium language server binary, same Connect-RPC service, same CSRF auth, same discovery process (ps + lsof + port probe), and same `GetUserStatus` RPC.

## Token Location

SQLite database — path depends on variant:

| Variant | Path |
|---|---|
| Windsurf | `~/Library/Application Support/Windsurf/User/globalStorage/state.vscdb` |
| Windsurf Next | `~/Library/Application Support/Windsurf - Next/User/globalStorage/state.vscdb` |

| Key | Value |
|---|---|
| `windsurfAuthStatus` | JSON: `{ apiKey: "sk-ws-01-...", ... }` |

## Plugin Strategy

1. Try each variant in order: Windsurf → Windsurf Next
2. Discover LS process via `ctx.host.ls.discover()` (ps + lsof) with variant-specific marker
3. Read API key from SQLite (`windsurfAuthStatus`) at variant-specific path
4. Probe ports with `GetUnleashData` to find the Connect-RPC endpoint
5. Call `GetUserStatus` with `apiKey` and variant-specific `ideName` in metadata
6. Build prompt + flex credit lines with billing cycle pacing (÷100 for display)
7. If no variant's LS is running: error "Start Windsurf and try again."
