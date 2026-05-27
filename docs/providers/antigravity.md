# Antigravity

> Reverse-engineered from app bundle and language server binary. May change without notice.

Antigravity is essentially a Google-branded fork of [Windsurf](windsurf.md) — both use the same Codeium language server binary and Connect-RPC protocol. The discovery, port probing, and RPC endpoints are virtually identical. The key differences: Antigravity uses fraction-based per-model quota (not credits), and doesn't require an API key in the request metadata.

## Overview

- **Vendor:** Google (internal codename "Jetski")
- **Protocol:** Connect RPC v1 (JSON over HTTP) on local language server
- **Service:** `exa.language_server_pb.LanguageServerService`
- **Auth:** CSRF token from process args; Google OAuth tokens from SQLite or `agy` keychain (fallbacks)
- **Quota:** fraction (0.0–1.0, where 1.0 = 100% remaining)
- **Quota window:** 5 hours
- **Timestamps:** ISO 8601
- **Requires:** Antigravity IDE or pre-rename Antigravity running, signed-in app credentials from either SQLite path, or an authenticated Antigravity CLI (`agy`)

## Discovery

The language server listens on a random localhost port. Three values must be discovered from the running process.

```bash
# 1. Find process and extract CSRF token
pgrep -ilf 'language_server.*antigravity|antigravity.*language_server'
# Match: --app_data_dir antigravity or antigravity-ide, OR matching app path
# Extract: --csrf_token <token>
# Extract: --extension_server_port <port>  (HTTP fallback)

# 2. Find listening ports
lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>

# 3. Probe each port to find the Connect-RPC endpoint
POST https://127.0.0.1:<port>/.../GetUnleashData  → first 200 OK wins
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

Returns plan info and per-model quota for all models (Gemini, Claude, GPT-OSS) in a single call.

```
POST http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetUserStatus
```

#### Request

```json
{
  "metadata": {
    "ideName": "antigravity",
    "extensionName": "antigravity",
    "ideVersion": "unknown",
    "locale": "en"
  }
}
```

#### Response

```jsonc
{
  "userStatus": {
    "planStatus": {
      "planInfo": {
        "planName": "Pro",                       // "Free" | "Pro" | "Teams" | "Ultra"
        "teamsTier": "TEAMS_TIER_PRO"
      }
    },

    "cascadeModelConfigData": {
      "clientModelConfigs": [
        {
          "label": "Gemini 3 Pro (High)",
          "modelOrAlias": { "model": "MODEL_PLACEHOLDER_M7" },
          "quotaInfo": {
            "remainingFraction": 1,              // 0.0–1.0
            "resetTime": "2026-02-07T14:23:01Z"
          }
        },
        {
          "label": "Claude Sonnet 4.5",
          "quotaInfo": { "remainingFraction": 1, "resetTime": "..." }
        },
        {
          "label": "Claude Opus 4.5 (Thinking)",
          "quotaInfo": { "remainingFraction": 1, "resetTime": "..." }
        },
        {
          "label": "GPT-OSS 120B (Medium)",
          "quotaInfo": { "remainingFraction": 1, "resetTime": "..." }
        }
        // ~7 models total, dynamic
      ]
    }
  }
}
```

### GetCommandModelConfigs (fallback)

Returns model configs with per-model quota only. No plan info, no email. Use when `GetUserStatus` fails.

```
POST http://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/GetCommandModelConfigs
```

#### Request

```json
{
  "metadata": {
    "ideName": "antigravity",
    "extensionName": "antigravity",
    "ideVersion": "unknown",
    "locale": "en"
  }
}
```

#### Response

```jsonc
{
  "clientModelConfigs": [
    // same shape as GetUserStatus.cascadeModelConfigData.clientModelConfigs
  ]
}
```

## Available Models

| Display Name | Internal ID | Provider |
|---|---|---|
| Gemini 3 Flash | 1018 | Google |
| Gemini 3 Pro (High) | 1008 | Google |
| Gemini 3 Pro (Low) | 1007 | Google |
| Claude Sonnet 4.5 | 333 | Anthropic (proxied) |
| Claude Sonnet 4.5 (Thinking) | 334 | Anthropic (proxied) |
| Claude Opus 4.6 (Thinking) | MODEL_PLACEHOLDER_M26 | Anthropic (proxied) |
| GPT-OSS 120B (Medium) | 342 | OpenAI (proxied) |

Models are dynamic — the list changes as Google adds/removes them. The plugin reads labels from the response, not a hardcoded list.

Interestingly, non-Google models (Claude, GPT-OSS) are proxied through Codeium/Windsurf infrastructure — Antigravity uses the same language server binary as Windsurf. The `GetUserStatus` response also includes `monthlyPromptCredits`, `monthlyFlowCredits`, and `monthlyFlexCreditPurchaseAmount` fields inherited from the Windsurf credit system, but these appear to be completely irrelevant to Antigravity's quota model which is purely fraction-based per model.

## Local SQLite Database

Antigravity stores auth credentials in a VS Code-compatible state database.

- **Paths (tried in order):** `~/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb`, then `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`
- **Table:** `ItemTable` (`key` TEXT, `value` TEXT)

### antigravityUnifiedStateSync.oauthToken (sentinel envelope → protobuf)

Google OAuth tokens are stored under this key in a double-wrapped base64 envelope.

Decoding layers:

1. Base64-decode the DB `value` → `outer` bytes.
2. `outer` field 1 (wire type 2) → `wrapper` bytes.
3. Inside `wrapper`: field 1 is the sentinel string `"oauthTokenInfoSentinelKey"`; field 2 is `payload` bytes.
4. Inside `payload`: field 1 (wire type 2) is a **UTF-8 base64 string** (not raw bytes).
5. Base64-decode that string → final `OAuthTokenInfo` protobuf.

```protobuf
message OAuthTokenInfo {
  string access_token = 1;              // "ya29...." Google OAuth access token
  string token_type = 2;                // ignored
  string refresh_token = 3;             // "1//..." Google OAuth refresh token
  Timestamp expiry = 4;                 // field 4, wire type 2
}
message Timestamp {
  int64 seconds = 1;                    // Unix epoch seconds
}
```

The plugin decodes this using a minimal protobuf wire-format parser (varint, length-delimited, fixed32, fixed64). The access token is short-lived; the refresh token is used to obtain new access tokens via Google OAuth.

### Token Refresh

```
POST https://oauth2.googleapis.com/token
Content-Type: application/x-www-form-urlencoded

client_id=1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com
&client_secret=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
&refresh_token=<refresh_token>
&grant_type=refresh_token
```

Response: `{ "access_token": "ya29...", "expires_in": 3599 }`

Same client_id/secret is there in the Antigravity app bundle, used for the Google OAuth refresh token.

## Cloud Code API (fallback)

When the language server is not running, the plugin falls back to Google's Cloud Code API using a Google OAuth access token (from the unified-state protobuf, or a cached refreshed token).

### fetchAvailableModels

```
POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels
Authorization: Bearer <access_token>
Content-Type: application/json
User-Agent: antigravity
```

Base URLs tried in order:
1. `https://daily-cloudcode-pa.googleapis.com`
2. `https://cloudcode-pa.googleapis.com`

#### Response

```jsonc
{
  "models": {
    "gemini-3-pro": {
      "displayName": "Gemini 3 Pro",
      "model": "gemini-3-pro",
      "quotaInfo": {
        "remainingFraction": 0.8,          // 0.0–1.0
        "resetTime": "2026-02-08T10:00:00Z"
      }
    }
    // ... more models
  }
}
```

Returns 401/403 if the token is invalid or expired — triggers reactive refresh.

The response includes all models provisioned for the account. The plugin filters out non-user-facing models using three layers: (1) `isInternal: true` flag from the API, (2) empty `displayName` (catches internal autocomplete models like `chat_20706`, `tab_flash_lite_preview`), and (3) a model-ID blacklist (catches Gemini 2.5 variants and placeholders).

The Cloud Code model set is a superset of the LS model set. The LS returns only cascade-configured chat models, Cloud Code includes all provisioned models. This difference is expected.

## Antigravity CLI (`agy`) fallback

The Antigravity CLI stores its own non-secret state under `~/.gemini/antigravity-cli/` and uses the OS keychain for auth. On macOS, current builds store the token under keychain service `gemini`, account `antigravity`.

OpenUsage treats this as a fallback inside the Antigravity provider, not a separate provider, because the app and CLI share the same account/model quota pools. The keychain value may be a raw bearer token, JSON OAuth-style payload, or `go-keyring-base64:` wrapped JSON payload.

CLI quota uses the same Cloud Code base URL but a different endpoint sequence:

1. `POST /v1internal:loadCodeAssist` with the `agy` OAuth token to read the paid tier and Cloud Code project.
2. `POST /v1internal:retrieveUserQuota` with `{ "project": "<cloudaicompanionProject>" }` to read quota buckets.

Current CLI quota buckets expose Gemini model pools. If the IDE is running, the language server remains preferred because it returns the full Antigravity model set, including Claude.

## Historical token/cost usage

Antigravity does not currently expose the local token/cost history that Claude and Codex use for `Today`, `Yesterday`, and `Last 30 Days` rows. The quota sources above return remaining fraction and reset time only. Antigravity CLI stores conversation state under `~/.gemini/antigravity-cli/`, but the local transcripts and logs do not include input, output, cache, or reasoning token counts, and the `.pb` conversation files are opaque without Google's private schema. Do not estimate token usage from transcript text or quota deltas; that would make the UI look precise while showing guessed data.

Gemini CLI usage data is separate (`${GEMINI_DATA_DIR:-~/.gemini/tmp}`) and must not be merged into Antigravity just because both tools use Google accounts.

## Plugin Strategy

1. **Strategy 1 — LS probe (primary):**
   a. Discover LS process via `ctx.host.ls.discover()` (ps + lsof)
   b. Probe ports with `GetUnleashData` to find the Connect-RPC endpoint
   c. Call `GetUserStatus` for plan name + per-model quota
   d. Fall back to `GetCommandModelConfigs` if `GetUserStatus` fails
2. **Strategy 2 — App Cloud Code API (fallback, only if LS fails):**
   a. Read `antigravityUnifiedStateSync.oauthToken` from SQLite, unwrap the sentinel envelope, and decode the inner `OAuthTokenInfo` protobuf (optional, may fail)
   b. Build candidate token list: proto access_token (if unexpired), cached refreshed token (if fresh), deduplicated
   c. Try each token with `fetchAvailableModels`
   d. If all fail with 401/403 (or the list is empty) and a refresh token is available: refresh via Google OAuth, cache result to pluginDataDir, retry once
   e. Parse model quota: skip `isInternal` models, empty-displayName models, and blacklisted model IDs
3. **Strategy 3 — CLI Cloud Code API (final fallback):**
   a. Read the `agy` keychain token from service `gemini`, account `antigravity`
   b. Call `loadCodeAssist` for plan/project context
   c. Call `retrieveUserQuota` for CLI quota buckets
4. If all strategies fail: error "Start Antigravity or run `agy` and try again."
