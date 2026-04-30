# OpenRouter

Tracks [OpenRouter](https://openrouter.ai) credit balance and spend.

## Overview

- **Protocol:** HTTPS (JSON)
- **Endpoint:** `GET https://openrouter.ai/api/v1/key`
- **Auth:** API key via environment variable (`OPENROUTER_API_KEY`)
- **Usage values:** USD spend for current month and all time
- **Credits model:** the plugin first tries the account credits endpoint, then falls back to per-key remaining limit fields

## Setup

1. Create or copy an API key from the [OpenRouter keys page](https://openrouter.ai/settings/keys)
2. Set `OPENROUTER_API_KEY`

OpenUsage is a GUI app. A one-off `export ...` in a terminal session will not be visible when you launch OpenUsage from
Spotlight/Launchpad. Persist it, then restart OpenUsage.

zsh (`~/.zshrc`):

```bash
export OPENROUTER_API_KEY="YOUR_API_KEY"
```

fish (universal var):

```fish
set -Ux OPENROUTER_API_KEY "YOUR_API_KEY"
```

3. Enable the OpenRouter plugin in OpenUsage settings

## Endpoint

### GET /api/v1/key

Returns metadata and spend totals for the current API key.

#### Headers

| Header | Required | Value |
|--------|----------|-------|
| Authorization | yes | `Bearer <api_key>` |
| Accept | yes | `application/json` |

#### Response

```json
{
  "data": {
    "label": "OpenClaw",
    "limit": 25,
    "usage": 4.5,
    "usage_daily": 0.5,
    "usage_weekly": 1.25,
    "usage_monthly": 2.75,
    "limit_remaining": 20.5,
    "is_free_tier": false
  }
}
```

Used fields:

- `limit` — spending cap in USD
- `usage` — lifetime spend in USD
- `usage_monthly` — current UTC month spend in USD
- `limit_remaining` — remaining spend under the configured cap
- `is_free_tier` — whether the key is on OpenRouter's free tier

### GET /api/v1/credits

OpenRouter's docs describe this as a management-key endpoint, but the plugin tries it opportunistically and falls back cleanly if the key cannot access it. When available, it returns total credits purchased and total credits used for the authenticated user.

Example response:

```json
{
  "data": {
    "total_credits": 110,
    "total_usage": 12.5
  }
}
```

## Displayed Lines

| Line | Description |
|------|-------------|
| Credits | Remaining account credits when `/credits` is available; otherwise remaining per-key limit; otherwise `No key limit` |
| This Month | Current UTC month spend |
| All Time | Lifetime spend |

## Notes

- The plugin uses `/api/v1/key` for all keys.
- The plugin also tries `/api/v1/credits`; if the key cannot access it, OpenUsage falls back to per-key limit fields from `/api/v1/key`.
- OpenRouter also exposes `/api/v1/activity`, but that still returned `403` in live testing for a standard key and is not used here.
- The plan label is simplified to `Free` or `Paid`.

## Errors

| Condition | Message |
|-----------|---------|
| No API key | `No OPENROUTER_API_KEY found. Set up environment variable first.` |
| 401/403 | `API key invalid. Check your OpenRouter API key.` |
| HTTP error | `Usage request failed (HTTP {status}). Try again later.` |
| Network error | `Usage request failed. Check your connection.` |
| Invalid JSON | `Usage response invalid. Try again later.` |
