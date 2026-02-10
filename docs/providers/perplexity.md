# Perplexity

> Reverse-engineered, undocumented API and local storage shape. May change without notice.

## Overview

- **Protocol:** local snapshot first, REST fallback
- **Primary local data source (v5.1):** `~/Library/Containers/ai.perplexity.mac/Data/Library/Preferences/ai.perplexity.mac.plist`
- **Fallback local data source:** `~/Library/Containers/ai.perplexity.mac/Data/Library/Caches/ai.perplexity.mac/Cache.db`
- **Fallback endpoint:** `GET https://www.perplexity.ai/api/user`

## Endpoint

### GET /api/user

Returns account profile + subscription metadata. Some accounts may also include usage/quota fields.

#### Request headers

| Header | Required | Value |
| --- | --- | --- |
| Authorization | yes | `Bearer <authToken>` |
| Accept | yes | `application/json` |
| X-Client-Name | recommended | `Perplexity-Mac` |
| X-App-ApiVersion | recommended | `2.17` |
| X-App-ApiClient | recommended | `macos` |
| X-Client-Env | recommended | `production` |

#### Sample response (sanitized)

```json
{
  "id": "user-id",
  "username": "example_user",
  "email": "user@example.com",
  "subscription_status": "none",
  "subscription_source": "none",
  "payment_tier": "none",
  "subscription_tier": "none",
  "is_in_organization": false
}
```

## Local app usage snapshot

Perplexity macOS v5.1 stores an app snapshot blob (`current_user__data`) in the same preferences plist.  
OpenUsage reads this first and only falls back to network when local usage fields are unavailable.

#### Example snapshot payload (sanitized)

```json
{
  "id": "user-id",
  "subscription": {
    "source": "none",
    "tier": "none",
    "paymentTier": "none",
    "status": "none"
  },
  "queryCount": 2,
  "uploadLimit": 3,
  "remainingUsage": {
    "remaining_pro": 1,
    "remaining_research": 0,
    "remaining_labs": 0
  }
}
```

## Authentication

### Token source priority

1. Extract usage snapshot from `current_user__data` in `ai.perplexity.mac.plist`.
2. Extract bearer token from `authToken` in `ai.perplexity.mac.plist`.
3. Fallback: extract bearer token from latest cached `/api/user` request object in `Cache.db`.

No API-key mode or env-var fallback is used in v1.

## OpenUsage mapping

- **Plan:** from `subscription_tier` / `payment_tier` (or snapshot `subscription.tier`/`paymentTier`).
  - If tier is `none`, OpenUsage shows `Free`.
- **Usage lines:**
  - `Pro` from `remaining_pro` with limit from explicit pro limit fields; for free-tier accounts only, `uploadLimit` is used as fallback.
    - `queryCount` is not used to infer `Pro` limit.
  - `Research` from `remaining_research` (+ optional limit fields if present)
  - `Labs` from `remaining_labs` (+ optional limit fields if present)
- If limits are present, render `progress` (`count` format).
- If only remaining values are present, OpenUsage persists per-metric baseline state and still renders `progress`:
  - state file: `app.pluginDataDir/usage-baseline.json`
  - cap priority: explicit limit -> pro-tier defaults (`Pro=600`, `Research=20`, `Labs=25`) -> persisted baseline -> cache high-water -> current remaining
  - used value: `max(0, cap - remaining)`
- If remaining increases (for example, after a reset/reclassification), baseline is raised and used decreases naturally.
- `Pro` / `Research` / `Labs` are quota bucket labels from backend fields and are not guaranteed 1:1 mappings to composer icon modes in the Perplexity UI.
- If logged in but no usable usage fields are found, show:
  - `Usage data unavailable. Open Perplexity app and run a search, then try again.`

## Error mapping

| Condition | Message |
| --- | --- |
| Missing token | `Not logged in. Sign in via Perplexity app.` |
| 401 / 403 (no local session snapshot) | `Token expired. Sign in via Perplexity app.` |
| 401 / 403 (local session snapshot exists) | `Usage data unavailable. Open Perplexity app and run a search, then try again.` |
| Network/transport failure | `Usage request failed. Check your connection.` |
| Non-2xx HTTP | `Usage request failed (HTTP {status}). Try again later.` |
| Invalid JSON | `Usage response invalid. Try again later.` |
