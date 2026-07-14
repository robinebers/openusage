# Factory (Droid)

> Reverse-engineered, undocumented API. May change without notice.

## Overview

- **Protocol:** REST (JSON)
- **Base URL:** `https://api.factory.ai`
- **Auth provider:** WorkOS (`api.workos.com`)
- **Client ID:** `client_01HNM792M5G5G1A2THWPXKFMXB`
- **Usage limits:** percentages for current Factory UI limits
- **Token counts:** integers (raw token counts, legacy response)
- **Timestamps:** unix milliseconds
- **Billing period:** ~27 days (monthly)

## What OpenUsage tracks

- Session (5-hour) usage for the Standard pool
- Weekly and monthly Standard usage when the account exposes UI-style limits
- Extra Usage prepaid balance
- Legacy Standard and Premium token pools for older billing responses
- Droid Core entitlement badge when present
- Managed computer hours when the compute endpoint is available

Authentication reuses the local Droid CLI session under `~/.factory`. Users do not paste credentials into OpenUsage.

## Endpoints

### POST /api/organization/subscription/usage

Returns Factory subscription usage. Current responses expose UI-style limits; older responses expose raw token allowances.

If this endpoint returns HTTP 405 for POST, OpenUsage retries with GET using `useCache=true` and, when decoded from the JWT, `userId` as query parameters.

### GET /api/billing/limits

Supplemental billing limits are requested only when subscription usage lacks UI-style limit fields and includes `globalLimit` or `userLimits`.

### GET /api/organization/compute-usage

Supplemental managed-computer usage is requested with billing limits. Some plans return HTTP 403 when managed computers are unavailable.

## Authentication

### Token location

- `~/.factory/auth.v2.file` + `~/.factory/auth.v2.key` (current Droid auth store; AES-256-GCM encrypted JSON)
- `~/.factory/auth.encrypted` (legacy Droid auth file)
- `~/.factory/auth.json` (older Droid auth file)
- macOS Keychain entry (when Droid uses keyring-backed storage)

```jsonc
{
  "access_token": "<WorkOS JWT>",
  "refresh_token": "<token>"
}
```

### Token refresh

Access tokens are refreshed when within 24 hours of expiry or after a 401/403 from the usage API.

```
POST https://api.workos.com/user_management/authenticate
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
&refresh_token=<refresh_token>
&client_id=client_01HNM792M5G5G1A2THWPXKFMXB
```

## Error states

| User-facing message | Meaning |
|---|---|
| Not logged in. Run `droid` to authenticate. | No Droid auth material was found locally. |
| Invalid Droid auth file. Run `droid` to authenticate. | Auth files exist but could not be parsed or decrypted. |
| Droid session expired. Run `droid` to log in again. | Refresh failed with an auth error. |
| Usage response invalid. Try again later. | The usage payload could not be parsed into displayable metrics. |
| Usage request failed. Check your connection. | Network/transport failure. |
| Usage request failed (HTTP …). Try again later. | Factory returned a non-auth HTTP error. |

## Prerequisites

The Droid CLI must be installed and authenticated:

```bash
droid
```

This creates auth data in the Droid auth store (file and/or Keychain, depending on Droid version and configuration).
