# Kiro

> Reverse-engineered from the shipped Kiro extension, local Kiro state, and local Kiro logs. The live API is not publicly documented and may change without notice.

## Overview

- **Product:** [Kiro](https://kiro.dev/)
- **Runtime service:** AWS CodeWhisperer Runtime (`https://q.<region>.amazonaws.com`)
- **Primary local state:** `~/Library/Application Support/Kiro/User/globalStorage/state.vscdb`
- **Primary local metadata fallback:** `~/Library/Application Support/Kiro/logs/*/window*/exthost/kiro.kiroAgent/q-client.log`
- **Auth token file:** `~/.aws/sso/cache/kiro-auth-token.json`
- **Profile fallback:** `~/Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/profile.json`

OpenUsage uses Kiro's local normalized usage cache first, enriches it from Kiro's own runtime logs when available, and only falls back to the live refresh/API path when the local picture is missing or stale.

## Plugin Metrics

| Metric | Source | Scope | Format | Notes |
| --- | --- | --- | --- | --- |
| Credits | `usageBreakdowns[*]` | overview | count | Monthly included Kiro plan credits |
| Bonus Credits | `freeTrialUsage` or active `bonuses[0]` | overview | count | Free-trial / bonus credit pool when present |
| Overages | `overageConfiguration.overageStatus` | detail | badge | `Enabled` / `Disabled` |

The plan label comes from `subscriptionInfo.subscriptionTitle` when a recent `GetUsageLimits` response is available from logs or the live API.

## Local Sources

### 1) SQLite usage cache

Path: `~/Library/Application Support/Kiro/User/globalStorage/state.vscdb`

Key:

- `kiro.kiroAgent`

That JSON currently contains a nested key:

- `kiro.resourceNotifications.usageState`

Observed shape:

```json
{
  "usageBreakdowns": [
    {
      "type": "CREDIT",
      "currentUsage": 0,
      "usageLimit": 50,
      "resetDate": "2026-05-01T00:00:00.000Z",
      "displayName": "Credit",
      "displayNamePlural": "Credits",
      "freeTrialUsage": {
        "currentUsage": 106.11,
        "usageLimit": 500,
        "expiryDate": "2026-05-03T15:09:55.196Z",
        "daysRemaining": 27
      }
    }
  ],
  "timestamp": 1775500185544
}
```

This is the cleanest local source for the numeric usage lines.

### 2) q-client runtime logs

Path pattern:

```text
~/Library/Application Support/Kiro/logs/<session>/window*/exthost/kiro.kiroAgent/q-client.log
```

Kiro logs the full `GetUsageLimitsCommand` request/response. That response includes the fields missing from the SQLite cache, especially:

- `subscriptionInfo.subscriptionTitle`
- `subscriptionInfo.type`
- `overageConfiguration.overageStatus`
- full `usageBreakdownList`

OpenUsage uses the latest logged response to recover plan metadata without needing network access.

## Authentication

### Token file

Kiro's desktop extension stores auth in:

```text
~/.aws/sso/cache/kiro-auth-token.json
```

Observed fields:

```json
{
  "accessToken": "...",
  "refreshToken": "...",
  "expiresAt": "2026-04-06T19:29:16.090Z",
  "authMethod": "social",
  "provider": "Google",
  "profileArn": "arn:aws:codewhisperer:us-east-1:699475941385:profile/..."
}
```

### Profile fallback

If `profileArn` is not embedded in the token file, Kiro also persists the selected profile:

```json
{
  "arn": "arn:aws:codewhisperer:us-east-1:699475941385:profile/...",
  "name": "Google"
}
```

## Live Refresh + Usage API

### Refresh social auth token

```http
POST https://prod.us-east-1.auth.desktop.kiro.dev/refreshToken
Content-Type: application/json
User-Agent: KiroIDE-<version>-<machineId>
```

```json
{
  "refreshToken": "<refresh_token>"
}
```

Observed refresh response fields:

- `accessToken`
- `refreshToken`
- `expiresIn`
- `profileArn`

### Fetch usage

```http
GET https://q.<region>.amazonaws.com/getUsageLimits?origin=AI_EDITOR&profileArn=<profileArn>&resourceType=AGENTIC_REQUEST
Authorization: Bearer <accessToken>
Accept: application/json
```

Extra headers used by Kiro only for specific auth modes:

- `TokenType: EXTERNAL_IDP` for external IdP accounts
- `redirect-for-internal: true` for internal AWS accounts

Observed response fields:

- `nextDateReset`
- `overageConfiguration.overageStatus`
- `subscriptionInfo.subscriptionTitle`
- `subscriptionInfo.type`
- `usageBreakdownList[*]`
- `userInfo.userId`

## Provider Strategy in OpenUsage

1. Require Kiro auth token presence so stale post-logout cache data is not shown as an active account.
2. Read `state.vscdb` for the normalized numeric usage view.
3. Read the latest `q-client.log` `GetUsageLimitsCommand` response for plan and overage metadata.
4. If the local cache is missing, incomplete, or older than the app's staleness threshold, call the live refresh/API path.
5. If live fetch fails but the local cache is usable, keep showing the last local snapshot.
