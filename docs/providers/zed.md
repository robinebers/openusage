# Zed AI

> Reverse-engineered, undocumented API. May change without notice.

## Overview

- **Protocol:** REST (plain JSON)
- **Base URL:** `https://cloud.zed.dev`
- **Auth:** Zed app credentials from the macOS Internet Password keychain item for `https://zed.dev`
- **Authorization header:** `<user_id> <access_token>`
- **Usage:** hosted model token spend and edit predictions

## Endpoints

### GET /frontend/billing/usage

Returns the personal billing summary shown by the Zed dashboard.

#### Headers

| Header | Required | Value |
|---|---:|---|
| Authorization | yes | `<user_id> <access_token>` |
| Accept | yes | `application/json` |
| Content-Type | yes | `application/json` |

#### Response

```jsonc
{
  "plan": "zed_pro",
  "is_account_too_young": false,
  "current_usage": {
    "token_spend": {
      "spend_in_cents": 125,
      "limit_in_cents": 500,
      "updated_at": "2026-06-01T12:00:00Z"
    },
    "edit_predictions": {
      "used": 120,
      "limit": 2000,
      "remaining": 1880
    }
  },
  "portal_url": "https://..."
}
```

### GET /frontend/billing/usage/tokens

Returns daily token spend for charting.

```jsonc
{
  "usage_by_model": {},
  "total_usage": [
    {
      "date": "2026-06-01",
      "tokens": {
        "input": 100,
        "input_cache_creation": 0,
        "input_cache_read": 0,
        "output": 25,
        "total": 125
      },
      "cost_in_cents": 10,
      "spend_in_cents": 10
    }
  ],
  "usage_cache_updated_at": "2026-06-01T12:00:00Z"
}
```

### GET /client/users/me

Fallback endpoint used by the Zed app. It returns account details plus `plan.plan_v3`, `plan.subscription_period`, and `plan.usage.edit_predictions`.

## Authentication

Zed stores production app credentials on macOS as an Internet Password keychain item:

```text
server: https://zed.dev
account: <user_id>
password: <access_token>
```

For local testing or manual setup, OpenUsage also accepts:

```text
ZED_USER_ID=<user_id>
ZED_ACCESS_TOKEN=<access_token>
```

## Notes

- Token spend comes from dashboard billing endpoints when available.
- If dashboard billing endpoints reject the app token or stop responding, OpenUsage falls back to `/client/users/me` and still shows edit prediction usage.
- Organization billing endpoints exist in the dashboard, but this provider currently tracks the signed-in personal account.
