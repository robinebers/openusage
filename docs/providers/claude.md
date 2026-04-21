# Claude Code

> Reverse-engineered, undocumented API. May change without notice.

## Overview

- **Protocol:** REST (plain JSON)
- **Base URL:** `https://api.anthropic.com`
- **Auth provider:** `platform.claude.com` (OAuth 2.0)
- **Client ID:** `9d1c250a-e61b-44d9-88ed-5944d1962f5e`
- **Beta header required:** `anthropic-beta: oauth-2025-04-20`
- **Utilization:** integer percentage (0-100)
- **Credits:** cents (divide by 100 for dollars)
- **Timestamps:** ISO 8601 (response), unix milliseconds (credentials file)
- **Peak hours status:** supplemental best-effort data from PromoClock's public API; does not affect Claude usage math

## Endpoints

### GET /api/oauth/usage

Returns rate limit windows and optional extra credits.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <access_token>` |
| Accept | yes | `application/json` |
| Content-Type | yes | `application/json` |
| anthropic-beta | yes | `oauth-2025-04-20` |

#### Response

```jsonc
{
  "five_hour": {
    "utilization": 25,              // % used in 5h rolling window
    "resets_at": "2026-01-28T15:00:00Z"
  },
  "seven_day": {
    "utilization": 40,              // % used in 7-day window
    "resets_at": "2026-02-01T00:00:00Z"
  },
  "seven_day_opus": {               // separate weekly Opus limit (optional, plan-dependent)
    "utilization": 0,
    "resets_at": "2026-02-01T00:00:00Z"
  },
  "seven_day_omelette": {           // separate weekly Claude Design limit (optional, plan-dependent)
    "utilization": 0,
    "resets_at": "2026-02-01T00:00:00Z"
  },
  "extra_usage": {                  // on-demand overage credits (optional)
    "is_enabled": true,
    "used_credits": 500,            // cents spent
    "monthly_limit": 10000,         // cents cap (0 = unlimited)
    "currency": "USD"
  }
}
```

All windows are enforced simultaneously — hitting any limit throttles the user.

### GET /api/oauth/profile

Returns the authenticated account + organization, including the live subscription
tier. Used to resolve the plan badge when the locally stored `rateLimitTier` /
`subscriptionType` have gone stale — those are snapshots written at login time
and are not refreshed when the user changes plan.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <access_token>` |
| Accept | yes | `application/json` |
| Content-Type | yes | `application/json` |
| anthropic-beta | yes | `oauth-2025-04-20` |

#### Response (fields consumed)

```jsonc
{
  "account": {
    "has_claude_max": true,
    "has_claude_pro": false
  },
  "organization": {
    "organization_type": "claude_max",            // or "claude_pro"
    "rate_limit_tier": "default_claude_max_20x"   // "...Nx" → "Nx" badge suffix
  }
}
```

`organization.rate_limit_tier` is preferred over the local
`claudeAiOauth.rateLimitTier`. The local value is used only as a fallback when
the profile call fails (network error, non-2xx, non-JSON).

## Supplemental Peak Hours Status

OpenUsage also augments the Claude card with PromoClock peak/off-peak status:

- **Endpoint:** `GET https://promoclock.co/api/status`
- **Auth:** none
- **Fields used:** `isPeak`, `isOffPeak`, `isWeekend`, `status` (fallback)
- **UI mapping:** binary Peak / Off-Peak badge (weekend is treated as off-peak)
- **Failure mode:** ignored on network, HTTP, or payload errors; Claude usage lines still render normally

This is informational only. PromoClock is an independent public service, not an official Anthropic API.

## Authentication

### Token Location

**Primary:** `~/.claude/.credentials.json`

```jsonc
{
  "claudeAiOauth": {
    "accessToken": "<jwt>",          // OAuth access token (Bearer)
    "refreshToken": "<token>",
    "expiresAt": 1738300000000,      // unix ms
    "scopes": ["..."],
    "subscriptionType": "pro",
    "rateLimitTier": "..."
  }
}
```

**Fallback:** macOS Keychain, service name `Claude Code-credentials` (same JSON structure).

### Token Refresh

Access tokens are short-lived JWTs. Refreshed proactively 5 minutes before expiration, or reactively on 401/403.

```
POST https://platform.claude.com/v1/oauth/token
Content-Type: application/json
```

```json
{
  "grant_type": "refresh_token",
  "refresh_token": "<refresh_token>",
  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers"
}
```

```jsonc
{
  "access_token": "<new_jwt>",
  "refresh_token": "<new_refresh_token>",  // may be same as previous
  "expires_in": 3600                       // seconds
}
```
