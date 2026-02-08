# Warp

> Uses Warp's GraphQL API with API key authentication.

## Overview

- **Protocol:** GraphQL
- **Base URL:** `https://app.warp.dev/graphql/v2`
- **Auth:** Bearer token (API key)
- **Credits:** count (requests used / request limit)
- **Timestamps:** ISO 8601

## Setup

### Get Your API Key

1. Open [Warp Settings > Account](https://app.warp.dev/settings/account)
2. Generate or copy your API key

### Configure the Plugin

Choose one of three methods (checked in this order):

1. **Environment variable** `WARP_API_KEY`

   ```bash
   export WARP_API_KEY="your-api-key-here"
   ```

2. **Environment variable** `WARP_TOKEN`

   ```bash
   export WARP_TOKEN="your-api-key-here"
   ```

3. **File** — Save your key to `api-key.txt` in the plugin data directory:

   ```
   ~/Library/Application Support/ai.openusage.app/plugins_data/warp/api-key.txt
   ```

   The file should contain just the API key, nothing else.

## Displayed Lines

| Line | Scope | Description |
|---|---|---|
| Credits | overview | Requests used vs. limit (progress bar) |
| Bonus | detail | Bonus credits from user + workspace grants |

If the account has unlimited credits, a badge shows "Unlimited" instead of a progress bar.

## Endpoint

### POST /graphql/v2?op=GetRequestLimitInfo

GraphQL query that fetches request limits and bonus grants.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <api_key>` |
| Content-Type | yes | `application/json` |
| x-warp-client-id | yes | `warp-app` |

#### Response

```jsonc
{
  "data": {
    "user": {
      "user": {
        "requestLimitInfo": {
          "isUnlimited": false,
          "nextRefreshTime": "2026-02-10T00:00:00Z",
          "requestLimit": 200,
          "requestsUsedSinceLastRefresh": 75
        },
        "bonusGrants": [                           // optional
          {
            "requestCreditsGranted": 50,
            "requestCreditsRemaining": 30,
            "expiration": null
          }
        ],
        "workspaces": [                            // optional
          {
            "bonusGrantsInfo": {
              "grants": [
                {
                  "requestCreditsGranted": 100,
                  "requestCreditsRemaining": 80,
                  "expiration": null
                }
              ]
            }
          }
        ]
      }
    }
  }
}
```

## Error Messages

| Message | Cause |
|---|---|
| No API key found | No env var or file configured |
| Invalid API key | 401/403 from Warp API |
| Warp API error (HTTP xxx) | Non-2xx response |
| Invalid response | Response body not valid JSON |
| Unexpected response | Missing expected data fields |
| Request failed | Network error or timeout |
