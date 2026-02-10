# Codex

> Reverse-engineered, undocumented API. May change without notice.

## Overview

- **Protocol:** REST (plain JSON)
- **Base URL:** `https://chatgpt.com`
- **Auth provider:** `auth.openai.com` (OAuth 2.0)
- **Client ID:** `app_EMoamEEZ73f0CkXaXp7hrann`
- **Percentages:** integers (0-100)
- **Timestamps:** unix seconds
- **Window durations:** seconds (18000 = 5h, 604800 = 7d)

## Endpoints

### GET /backend-api/wham/usage

Returns rate limit windows and optional credits.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <access_token>` |
| Accept | yes | `application/json` |
| ChatGPT-Account-Id | no | `<account_id>` |

#### Response

```jsonc
{
  "plan_type": "plus",                     // plan tier
  "rate_limit": {
    "primary_window": {
      "used_percent": 6,                   // % used in 5h rolling window
      "reset_at": 1738300000,              // unix seconds
      "limit_window_seconds": 18000        // 5 hours
    },
    "secondary_window": {
      "used_percent": 24,                  // % used in 7-day window
      "reset_at": 1738900000,
      "limit_window_seconds": 604800       // 7 days
    }
  },
  "code_review_rate_limit": {              // separate weekly code review limit (optional)
    "primary_window": {
      "used_percent": 0,
      "reset_at": 1738900000,
      "limit_window_seconds": 604800
    }
  },
  "credits": {                             // purchased credits (optional)
    "has_credits": true,
    "unlimited": false,
    "balance": 5.39                        // remaining balance
  }
}
```

Both rate_limit windows are enforced simultaneously — hitting either limit throttles the user.

## Authentication

### Credential Storage Locations

Codex CLI supports multiple credential storage modes:

- **file** (default): `CODEX_HOME/auth.json` (or `~/.codex/auth.json` by default)
- **keyring**: OS keychain/credential manager entry (service name `Codex Auth`)
- **auto**: keyring first, fallback to file
- **ephemeral**: memory-only (no persistence)

For `keyring`/`auto`, Codex may not keep `auth.json` on disk. If keyring save succeeds, Codex removes the fallback `auth.json`.

OpenUsage Codex plugin auth lookup order:

1. `CODEX_HOME/auth.json` (when `CODEX_HOME` is set)
2. `~/.config/codex/auth.json`
3. `~/.codex/auth.json`
4. macOS keychain service `Codex Auth` (fallback)

Keychain fallback is available on macOS only.

Expected auth payload shape (file or keychain JSON value):

```jsonc
{
  "OPENAI_API_KEY": null,                  // legacy API key field
  "tokens": {
    "access_token": "<jwt>",               // OAuth access token (Bearer)
    "refresh_token": "<token>",
    "id_token": "<jwt>",                   // OpenID Connect ID token
    "account_id": "<uuid>"                 // sent as ChatGPT-Account-Id header
  },
  "last_refresh": "2026-01-28T08:05:37Z"  // ISO 8601
}
```

> Note: Codex also stores MCP OAuth tokens in `~/.codex/.credentials.json` (or keyring), but that is separate from ChatGPT CLI auth used by this plugin.

### Token Refresh

Access tokens are short-lived JWTs. Refreshed when `last_refresh` is older than 8 days, or on 401/403.

```
POST https://auth.openai.com/oauth/token
Content-Type: application/x-www-form-urlencoded
```

```
grant_type=refresh_token
&client_id=app_EMoamEEZ73f0CkXaXp7hrann
&refresh_token=<refresh_token>
```

Response returns new `access_token`, and optionally new `refresh_token` and `id_token`.
