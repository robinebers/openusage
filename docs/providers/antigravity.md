# Antigravity

> Reverse-engineered from app bundle and language server binary. May change without notice.

Antigravity is essentially a Google-branded fork of [Windsurf](windsurf.md) — both use the same Codeium language server binary and Connect-RPC protocol. The discovery, port probing, and RPC endpoints are virtually identical. The key differences: Antigravity uses fraction-based per-model quota (not credits), and doesn't require an API key in the request metadata.

## Overview

- **Vendor:** Google (internal codename "Jetski")
- **Protocol:** Connect RPC v1 (JSON over HTTP) on local language server
- **Service:** `exa.language_server_pb.LanguageServerService`
- **Auth:** CSRF token from process args, API key from SQLite (fallback)
- **Quota:** fraction (0.0–1.0, where 1.0 = 100% remaining)
- **Quota window:** 5 hours
- **Timestamps:** ISO 8601
- **Requires:** Antigravity IDE running (language server process), or signed-in credentials in SQLite (Cloud Code fallback)

## Discovery

The language server listens on a random localhost port. Three values must be discovered from the running process.

```bash
# 1. Find process and extract CSRF token
ps -ax -o pid=,command= | grep 'language_server_macos.*antigravity'
# Match: --app_data_dir antigravity  OR  path contains /antigravity/
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

The CSRF token alone authenticates. When an API key is available from the local SQLite database, it is included in the metadata.

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
| Claude Opus 4.5 (Thinking) | 1012 | Anthropic (proxied) |
| GPT-OSS 120B (Medium) | 342 | OpenAI (proxied) |

Models are dynamic — the list changes as Google adds/removes them. The plugin reads labels from the response, not a hardcoded list.

Interestingly, non-Google models (Claude, GPT-OSS) are proxied through Codeium/Windsurf infrastructure — Antigravity uses the same language server binary as Windsurf. The `GetUserStatus` response also includes `monthlyPromptCredits`, `monthlyFlowCredits`, and `monthlyFlexCreditPurchaseAmount` fields inherited from the Windsurf credit system, but these appear to be completely irrelevant to Antigravity's quota model which is purely fraction-based per model.

## Local SQLite Database

Antigravity stores auth credentials in a VS Code-compatible state database.

- **Path:** `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`
- **Table:** `ItemTable` (`key` TEXT, `value` TEXT)

### antigravityAuthStatus

```json
{
  "apiKey": "ya29.<token>",
  "email": "user@example.com",
  "name": "Test User"
}
```

`apiKey` is a Google OAuth access token (`ya29...`). It's included in LS metadata and used as a last-resort Bearer token for Cloud Code when protobuf OAuth tokens are unavailable. It appears to be a separately-issued copy of the same kind of token stored in the protobuf data below.

### jetskiStateSync.agentManagerInitState (protobuf)

Google OAuth tokens are also stored as a base64-encoded protobuf blob, with the addition of a refresh token and expiry timestamp.

```protobuf
message AgentManagerInitState {
  OAuthTokenInfo oauth_token = 6;       // field 6, wire type 2
}
message OAuthTokenInfo {
  string access_token = 1;              // "ya29...." Google OAuth access token
  string token_type = 2;               // ignored
  string refresh_token = 3;            // "1//..." Google OAuth refresh token
  Timestamp expiry = 4;                // field 4, wire type 2
}
message Timestamp {
  int64 seconds = 1;                   // Unix epoch seconds
}
```

The plugin decodes this using a minimal protobuf wire-format parser (varint + length-delimited only). The access token is short-lived; the refresh token is used to obtain new access tokens via Google OAuth.

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

When the language server is not running, the plugin falls back to Google's Cloud Code API using a Google OAuth access token (from protobuf data, or apiKey as last resort).

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

## Plugin Strategy

1. Read `antigravityAuthStatus` from SQLite for API key (optional, may fail)
2. Read `jetskiStateSync.agentManagerInitState` from SQLite, decode protobuf for OAuth tokens (optional, may fail)
3. **Strategy 1 — LS probe (primary):**
   a. Discover LS process via `ctx.host.ls.discover()` (ps + lsof)
   b. Probe ports with `GetUnleashData` to find the Connect-RPC endpoint
   c. Include `apiKey` in metadata if available
   d. Call `GetUserStatus` for plan name + per-model quota
   e. Fall back to `GetCommandModelConfigs` if `GetUserStatus` fails
4. **Strategy 2 — Cloud Code API (fallback, only if LS fails):**
   a. Build candidate token list: proto access_token, cached refreshed token (if fresh), apiKey (all deduplicated)
   b. Try each token with `fetchAvailableModels`
   c. If all fail with 401/403 and refresh token available: refresh via Google OAuth, cache result to pluginDataDir, retry once
   d. Parse model quota: skip `isInternal` models, empty-displayName models, and blacklisted model IDs
5. If both strategies fail: error "Start Antigravity and try again."
