# Factory (Droid)

> Reverse-engineered, undocumented API. May change without notice.

## Overview

- **Protocol:** REST (JSON)
- **Base URL:** `https://api.factory.ai`
- **Auth provider:** WorkOS (`api.workos.com`)
- **Client ID:** `client_01HNM792M5G5G1A2THWPXKFMXB`
- **Token counts:** integers (raw token counts)
- **Timestamps:** unix milliseconds
- **Billing period:** ~27 days (monthly)

## Endpoints

### POST /api/organization/subscription/usage

Returns token usage for the current billing period.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <access_token>` |
| Content-Type | yes | `application/json` |
| Accept | no | `application/json` |

#### Request Body

```json
{
  "useCache": true
}
```

#### Response

```jsonc
{
  "usage": {
    "startDate": 1770623326000,         // billing period start (unix ms)
    "endDate": 1772956800000,           // billing period end (unix ms)
    "standard": {
      "userTokens": 0,                  // user's token usage
      "orgTotalTokensUsed": 5000000,    // org total tokens used
      "orgOverageUsed": 0,              // overage tokens used
      "basicAllowance": 20000000,       // base allowance
      "totalAllowance": 20000000,       // total (base + bonus)
      "orgOverageLimit": 0,             // overage limit
      "usedRatio": 0.25                 // usage ratio (0-1)
    },
    "premium": {
      "userTokens": 0,
      "orgTotalTokensUsed": 0,
      "orgOverageUsed": 0,
      "basicAllowance": 0,              // 0 for Pro, >0 for Max/Enterprise
      "totalAllowance": 0,
      "orgOverageLimit": 0,
      "usedRatio": 0
    }
  },
  "source": "cache",                    // "cache" or "live"
  "cacheUpdated": false
}
```

### GET /api/billing/limits

Returns current Factory/Droid quota windows shown in the web app.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <access_token>` |
| Accept | no | `application/json` |

#### Response

```jsonc
{
  "limits": {
    "standard": {
      "fiveHour": { "usedPercent": 0.12, "windowEnd": 1770626926000, "secondsRemaining": 1200 },
      "weekly": { "usedPercent": 0.34, "windowEnd": 1771228126000, "secondsRemaining": 604800 },
      "monthly": { "usedPercent": 0.56, "windowEnd": 1772956800000, "secondsRemaining": 2333474 }
    },
    "core": {
      "enabled": true
    }
  },
  "extraUsageBalanceCents": 1200,
  "usesTokenRateLimitsBilling": true
}
```

### GET /api/organization/compute-usage

Returns Droid Core / managed computer usage for the current period.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <access_token>` |
| Accept | no | `application/json` |

#### Response

```jsonc
{
  "orgUsageMs": 3600000,
  "limitMs": 7200000,
  "periodStart": 1770623326000,
  "periodEnd": 1772956800000
}
```

### Plan Detection

Plan is inferred from `standard.totalAllowance` and Droid Core fields:

| Allowance | Plan |
|---|---|
| 200M+ | Max |
| 20M+ | Pro |
| >0 | Basic |

Premium tokens (`premium.totalAllowance > 0`) are only available on Max/Enterprise plans.
Droid Core/managed computer usage adds `+ Droid Core` when enabled.

## Authentication

### Token Location

- `~/.factory/auth.v2.file` + `~/.factory/auth.v2.key` (current droid auth store; AES-256-GCM encrypted JSON)
- `~/.factory/auth.encrypted` (legacy droid auth file)
- `~/.factory/auth.json` (older droid auth file)
- macOS keychain entry (when droid uses keyring-backed storage)

```jsonc
{
  "access_token": "<WorkOS JWT>",       // ~1329 chars, 7-day lifetime
  "refresh_token": "<token>"            // 25-char WorkOS session token
}
```

### JWT Payload Structure

```jsonc
{
  "exp": 1738900000,                    // expiry (unix seconds)
  "org_id": "org_xxx",                  // organization ID
  "email": "user@example.com",
  "roles": ["owner"]
}
```

### Token Refresh

Access tokens have a 7-day lifetime. Refreshed when within 24 hours of expiry or on 401/403.

```
POST https://api.workos.com/user_management/authenticate
Content-Type: application/x-www-form-urlencoded
```

```
grant_type=refresh_token
&refresh_token=<refresh_token>
&client_id=client_01HNM792M5G5G1A2THWPXKFMXB
```

#### Response

```jsonc
{
  "access_token": "<new_jwt>",
  "refresh_token": "<new_refresh_token>",
  "user": { ... },
  "organization_id": "org_xxx"
}
```

## Prerequisites

The droid CLI must be installed and authenticated:

```bash
# Install droid CLI (if not already installed)
# Then authenticate:
droid
# Follow OAuth flow in browser
```

This creates auth data in the droid auth store (file and/or keychain, depending on droid version/configuration).
