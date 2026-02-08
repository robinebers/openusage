# Droid (Factory)

> Reverse-engineered, undocumented API. May change without notice.

## Overview

- **Protocol:** REST (JSON)
- **Base URLs tried:**
  - `https://auth.factory.ai`
  - `https://api.factory.ai`
  - `https://app.factory.ai`
- **Auth backend:** WorkOS (`api.workos.com`)

## Endpoints

### GET `/api/app/auth/me`

Returns organization and subscription metadata.

### POST `/api/organization/subscription/usage`

Request body:

```json
{ "useCache": true }
```

Returns usage windows for token pools (standard/premium), including start/end billing timestamps.

## Authentication Sources

OpenUsage Droid plugin attempts, in order:

1. Manual cookie header file: `{pluginDataDir}/cookie-header.txt`
2. CodexBar session file: `~/Library/Application Support/CodexBar/factory-session.json`
3. WorkOS refresh token from the same session file

Session file fields used:

- `cookies` (array)
- `bearerToken`
- `refreshToken`

If refresh token exists, plugin calls:

`POST https://api.workos.com/user_management/authenticate`

with:

- `grant_type=refresh_token`
- one of known `client_id` values
- `refresh_token`

## Output Mapping

- `usage.standard` -> **Standard** progress line
- `usage.premium` -> **Premium** progress line
- `usage.startDate` / `usage.endDate` -> `resetsAt` and `periodDurationMs`
- Organization name (if available) -> **Organization** detail line

Plan label combines Factory tier and plan when available.

## Manual Cookie Setup

If auto-detection fails, create:

`{pluginDataDir}/cookie-header.txt`

with content like:

```text
Cookie: wos-session=...; access-token=...
```

Then refresh OpenUsage.
