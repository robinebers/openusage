# Grok

Tracks Grok Build credit usage from the local Grok CLI login.

> Reverse-engineered, undocumented API. May change without notice.

## Overview

- **Protocol:** REST (plain JSON)
- **Base URL:** `https://cli-chat-proxy.grok.com/v1`
- **Auth:** cached Grok CLI token from `~/.grok/auth.json`
- **Usage unit:** raw billing units from Grok
- **Plan source:** `GET /settings` (`subscription_tier_display`)
- **Reset period:** billing period from the CLI billing response

## Setup

1. Install and sign in to the Grok CLI:

```bash
grok login
```

2. Enable the Grok plugin in OpenUsage settings.

OpenUsage reads the same local auth file that the Grok CLI uses. If the token expires, run `grok login` again.

## Endpoint

### GET /billing

Returns the current Grok Build billing period, credit usage, and pay-as-you-go cap.

#### Headers

| Header | Required | Value |
|--------|----------|-------|
| Authorization | yes | `Bearer <token from ~/.grok/auth.json>` |
| X-XAI-Token-Auth | yes | `xai-grok-cli` |
| Accept | yes | `application/json` |

#### Response

```json
{
  "config": {
    "monthlyLimit": { "val": 60000 },
    "used": { "val": 4277 },
    "onDemandCap": { "val": 0 },
    "billingPeriodStart": "2026-05-01T00:00:00+00:00",
    "billingPeriodEnd": "2026-06-01T00:00:00+00:00",
    "history": [
      {
        "billingCycle": { "year": 2026, "month": 4 },
        "includedUsed": { "val": 0 },
        "onDemandUsed": { "val": 0 },
        "totalUsed": { "val": 0 }
      }
    ]
  }
}
```

### GET /settings

Returns remote CLI settings. OpenUsage reads `subscription_tier_display` from this response and shows it as the provider plan label, for example `SuperGrok Heavy`.

Used fields:

- `used.val` — current billing period usage
- `monthlyLimit.val` — included credit limit
- `onDemandCap.val` — pay-as-you-go cap; `0` means disabled
- `billingPeriodEnd` — current billing period reset time

## Displayed Lines

| Line | Description |
|------|-------------|
| Credits used | Percent of included monthly credits used |
| Pay as you go | Disabled, or the configured pay-as-you-go cap |

## Errors

| Condition | Message |
|-----------|---------|
| Missing auth file | "Grok not logged in. Run `grok login`." |
| Expired token | "Grok auth expired. Run `grok login` again." |
| 401/403 | "Grok auth expired. Run `grok login` again." |
| HTTP error | "Grok billing request failed (HTTP {status}). Try again later." |
| Network error | "Grok billing request failed. Check your connection." |
| Invalid response | "Grok billing response changed." |
