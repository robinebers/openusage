# Synthetic

## Overview

- **Protocol:** REST (`GET /v2/quotas`)
- **URL:** `https://api.synthetic.new/v2/quotas`
- **Auth:** API key discovered from Pi, Factory/Droid, OpenCode, or `SYNTHETIC_API_KEY` env var
- **Tier:** Subscription packs ($30/month base) with rolling rate limits

## Authentication

The plugin searches multiple sources for a Synthetic API key, checking under the provider names `synthetic`, `synthetic.new`, and `syn`. The first key found wins.

### Credential Sources (checked in order)

**1. Pi auth.json** — `~/.pi/agent/auth.json`

```json
{
  "synthetic": {
    "type": "api_key",
    "key": "syn_..."
  }
}
```

The Pi agent directory can be overridden via the `PI_CODING_AGENT_DIR` environment variable (e.g. `PI_CODING_AGENT_DIR=~/custom/pi`).

**2. Pi models.json** — `~/.pi/agent/models.json`

For users who configured Synthetic as a custom provider in Pi:

```json
{
  "providers": {
    "synthetic": {
      "apiKey": "syn_..."
    }
  }
}
```

**3. Factory/Droid settings.json** — `~/.factory/settings.json`

For users who configured Synthetic as a custom model in Factory/Droid. The plugin scans the `customModels` array for any entry with a `baseUrl` containing `synthetic.new`:

```json
{
  "customModels": [
    {
      "baseUrl": "https://api.synthetic.new/openai/v1",
      "apiKey": "syn_...",
      "displayName": "Kimi K2.5 [Synthetic]"
    }
  ]
}
```

**4. OpenCode auth.json** — `~/.local/share/opencode/auth.json`

```json
{
  "synthetic": {
    "key": "syn_..."
  }
}
```

**5. Environment variable** — `SYNTHETIC_API_KEY`

Falls back to the `SYNTHETIC_API_KEY` environment variable if no file source contains a key.

The key is sent as `Authorization: Bearer <key>` to the quotas API.

## Data Source

### API Endpoint

```
GET https://api.synthetic.new/v2/quotas
Authorization: Bearer <api_key>
Accept: application/json
```

Quota checks do not count against subscription limits.

### Response

```json
{
  "subscription": {
    "limit": 600,
    "requests": 0,
    "renewsAt": "2026-04-30T20:18:54.144Z"
  },
  "search": {
    "hourly": {
      "limit": 250,
      "requests": 0,
      "renewsAt": "2026-03-30T16:18:54.145Z"
    }
  },
  "weeklyTokenLimit": {
    "nextRegenAt": "2026-03-30T16:20:39.000Z",
    "percentRemaining": 100
  },
  "rollingFiveHourLimit": {
    "nextTickAt": "2026-03-30T15:30:29.000Z",
    "tickPercent": 0.05,
    "remaining": 600,
    "max": 600,
    "limited": false
  }
}
```

### Quota Systems

Synthetic uses two complementary rate limiting systems:

**Rolling 5-hour limit** — burst rate control:
- `remaining` / `max` requests in a rolling 5-hour window
- Every ~15 minutes, 5% of `max` is restored (a "tick")
- `limited` is `true` when `remaining` hits 0
- `max` varies by subscription level (e.g. 400 standard, 600 founder's pack)

**Weekly mana bar** — longer-term budget:
- A single quota that scales by token costs and cache hits (cache hits discounted 80%)
- Regenerates 2% every ~3.36 hours (full regen in one week)
- `percentRemaining` (0–100) tracks how much budget remains

**Subscription** — legacy request count per billing period.

**Search** — separate hourly quota for search requests.

## Plan Detection

No plan name is returned by the API. The plugin does not set a plan label.

## Displayed Lines

| Line            | Scope    | Condition                                                 | Description                                   |
|-----------------|----------|-----------------------------------------------------------|-----------------------------------------------|
| 5h Rate Limit   | overview | `rollingFiveHourLimit.max` and `remaining` are numeric    | Usage in 5-hour rolling window (used / limit) |
| Mana Bar        | overview | `weeklyTokenLimit.percentRemaining` is numeric            | Weekly token budget as percentage used        |
| Rate Limited    | detail   | `rollingFiveHourLimit.limited`                            | Red badge shown only when actively rate limited |
| Subscription    | overview | `subscription` present and no usable v3 quota lines exist | Legacy request count for billing period       |
| Free Tool Calls | detail   | `freeToolCalls.limit > 0` and no usable v3 quota lines exist | Legacy free tool-call quota                |
| Search          | detail   | `search.hourly` present                                   | Hourly search request quota                   |

5h Rate Limit is the primary (tray icon) metric — it's the first constraint users hit during active use.

Progress lines include:
- 5h Rate Limit / Mana Bar: usage fields only, with no reset metadata
- Subscription / Free Tool Calls: `resetsAt` from `renewsAt`
- Search: `resetsAt` from `renewsAt` and `periodDurationMs = 3600000`

## Errors

| Condition              | Message                                                                   |
|------------------------|---------------------------------------------------------------------------|
| No API key found       | "Synthetic API key not found. Set SYNTHETIC_API_KEY or add key to ~/.pi/agent/auth.json" |
| 401/403                | "API key invalid or expired. Check your Synthetic API key."               |
| Non-2xx with detail    | Error message from API response                                           |
| Non-2xx without detail | "Request failed (HTTP {status})"                                          |
| Unparseable response   | "Could not parse usage data."                                             |
| Network error          | "Request failed. Check your connection."                                  |
