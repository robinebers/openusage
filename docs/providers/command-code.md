# Command Code

> Uses the Command Code billing API to track plan credits usage.

## Overview

- **Source of truth:** `https://api.commandcode.ai`
- **Auth discovery:** `~/.commandcode/auth.json`
- **Provider ID:** `command-code`
- **Usage scope:** account-level monthly plan credits

## Detection

The plugin enables when `~/.commandcode/auth.json` exists and contains a non-empty `apiKey`.

If the secrets file is missing, the plugin stays hidden.

## Data Source

OpenUsage calls two Command Code API endpoints:

```
GET https://api.commandcode.ai/alpha/billing/credits
GET https://api.commandcode.ai/alpha/billing/subscriptions
```

Both are authenticated with `Authorization: Bearer <apiKey>`.

### Credits Response

```jsonc
{
  "credits": {
    "monthlyCredits": 9.9859       // remaining plan credits
  }
}
```

### Subscriptions Response

```jsonc
{
  "success": true,
  "data": {
    "planId": "individual-go",
    "currentPeriodEnd": "2026-06-05T07:58:40.000Z"
  }
}
```

`planId` determines which plan limit applies.

## Limits

OpenUsage uses the current published Command Code plan limits:

- `individual-go`: `$10`
- `individual-pro`: `$30`
- `individual-max`: `$150`
- `individual-ultra`: `$300`
- `teams-pro`: `$40`

Bars show used credits in dollars (plan label) and as a percentage (Monthly Quota), clamped at `100%`.

## Window Rules

- **Period:** subscription billing period (`currentPeriodStart` - `currentPeriodEnd` from the API)
- **Resets at:** the `currentPeriodEnd` timestamp returned by the API

Usage is account-level from the API, not estimated from local history.

## Failure Behavior

| Condition | Behavior |
|---|---|
| Secrets file missing | Plugin hidden |
| API returns 401/403 | Red error: `Session expired. Re-authenticate in CommandCode.` |
| API returns HTTP error | Red error with status code or detail message |
| Network failure | Red error: `Request failed. Check your connection.` |
| Unexpected response structure | Red error: `Could not parse usage data.` |

## Future Compatibility

The public provider identity stays `command-code`. If Command Code later changes billing endpoint paths or response schemas, OpenUsage can update the plugin without changing the provider ID or UI contract.
