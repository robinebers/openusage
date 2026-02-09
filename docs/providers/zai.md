# Z.ai

Tracks [Z.ai](https://z.ai) (Zhipu AI) usage quotas for GLM coding plans.

> These API endpoints are not documented in Z.ai's public API reference. They are used internally by the subscription management UI and work with both OAuth tokens and API keys.

## Overview

- **Protocol:** REST (plain JSON)
- **Base URL:** `https://open.bigmodel.cn`
- **Auth:** API key via macOS Keychain
- **Keychain service:** `OpenUsage-zai`
- **Session utilization:** percentage (0-100)
- **Web searches:** count-based (used / limit)
- **Reset periods:** 5 hours (session), monthly (web searches, from subscription renewal date)

## Setup

1. [Subscribe to a GLM Coding plan](https://z.ai/subscribe) and get your API key from the [Z.ai console](https://z.ai/manage-apikey/apikey-list)
2. Store it in the macOS Keychain:

```bash
security add-generic-password -s OpenUsage-zai -a OpenUsage -w "YOUR_API_KEY" -U
```

3. Enable the Z.ai plugin in OpenUsage settings

## Endpoints

### GET /api/biz/subscription/list

Returns the user's active subscription(s). Used to extract the plan name and monthly renewal date.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <api_key>` |
| Accept | yes | `application/json` |

#### Response

```json
{
  "code": 200,
  "data": [
    {
      "id": "169359",
      "customerId": "71321768207710758",
      "productName": "GLM Coding Max",
      "description": "-All Pro plan benefits\n-4× Pro plan usage...",
      "status": "VALID",
      "purchaseTime": "2026-01-12 16:55:13",
      "valid": "2026-02-12 16:55:13-2026-03-12 16:55:13",
      "autoRenew": 1,
      "initialPrice": 30.0,
      "actualPrice": 30.0,
      "currentPeriod": 2,
      "currentRenewTime": "2026-01-12",
      "nextRenewTime": "2026-02-12",
      "billingCycle": "monthly",
      "inCurrentPeriod": true,
      "paymentChannel": "STRIPE"
    }
  ],
  "success": true
}
```

Used fields:
- `productName` — plan display name (e.g. "GLM Coding Max")
- `nextRenewTime` — monthly reset date for web search quota (ISO date, e.g. "2026-03-12")

### GET /api/monitor/usage/quota/limit

Returns session token usage and web search quotas.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <api_key>` |
| Accept | yes | `application/json` |

#### Response

```json
{
  "code": 200,
  "data": {
    "limits": [
      {
        "type": "TOKENS_LIMIT",
        "unit": 3,
        "number": 5,
        "usage": 800000000,
        "currentValue": 127694464,
        "remaining": 672305536,
        "percentage": 15,
        "nextResetTime": 1770648402389
      },
      {
        "type": "TIME_LIMIT",
        "unit": 5,
        "number": 1,
        "usage": 4000,
        "currentValue": 1828,
        "remaining": 2172,
        "percentage": 45,
        "usageDetails": [
          { "modelCode": "search-prime", "usage": 1433 },
          { "modelCode": "web-reader", "usage": 462 },
          { "modelCode": "zread", "usage": 0 }
        ]
      }
    ]
  },
  "success": true
}
```

**TOKENS_LIMIT:**
- `usage` — total token limit (e.g. 800M)
- `currentValue` — tokens consumed
- `remaining` — tokens remaining
- `percentage` — usage as percentage (0-100)
- `nextResetTime` — epoch milliseconds of next reset
- `unit: 3, number: 5` — 5-hour rolling period

**TIME_LIMIT:**
- `usage` — total web search/reader call limit (e.g. 4000)
- `currentValue` — calls consumed
- `remaining` — calls remaining
- `percentage` — usage as percentage (0-100)
- `usageDetails` — per-model breakdown (search-prime, web-reader, zread)
- `unit: 5, number: 1` — monthly period (no `nextResetTime`; resets on the 1st of each month at 00:00 UTC)

## Displayed Lines

| Line | Description |
|------|-------------|
| Session | Token usage as percentage (0-100%) with 5h reset timer |
| Web Searches | Web search/reader call count (used / limit), resets on the 1st of each month |

## Errors

| Condition | Message |
|-----------|---------|
| No API key | "API key not configured. Store it with: `security add-generic-password -s OpenUsage-zai -a OpenUsage -w "YOUR_KEY" -U`" |
| 401/403 | "API key invalid. Check your Z.ai API key." |
| HTTP error | "Usage request failed (HTTP {status}). Try again later." |
| Network error | "Usage request failed. Check your connection." |
| Invalid JSON | "Usage response invalid. Try again later." |
