# Cursor

> Reverse-engineered, undocumented API. May change without notice.

## Overview

- **Protocol:** Connect RPC v1 (JSON over HTTP)
- **Base URL:** `https://api2.cursor.sh`
- **Service:** `aiserver.v1.DashboardService`
- **Auth provider:** Auth0 (via Cursor)
- **Client ID:** `KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB`
- **Amounts:** cents (divide by 100 for dollars)
- **Timestamps:** unix milliseconds (as strings)

## Plugin metrics

| Metric | Source field | Scope | Format | Notes |
|---|---|---|---|---|
| Credits | `GetCreditGrantsBalance` | overview | dollars | Only when `hasCreditGrants` is true |
| Total usage | `planUsage.totalPercentUsed` | overview | percent (individual) / dollars (team) | Falls back to computed `(limit - remaining) / limit * 100` when `totalPercentUsed` is not finite. Team accounts use dollars format. |
| Auto usage | `planUsage.autoPercentUsed` | detail | percent | Omitted when field is missing or non-finite |
| API usage | `planUsage.apiPercentUsed` | detail | percent | Omitted when field is missing or non-finite |
| Requests | `/api/usage` (enterprise) | overview | count | Enterprise accounts only; unchanged from previous behavior |
| On-demand | `spendLimitUsage` | detail | dollars | Only when individual or pooled limit > 0 |

**Enterprise flow** remains request-based via the REST `/api/usage` endpoint -- unchanged.

**Team detection**: an account is treated as "team" when `planName` is `"Team"`, or `spendLimitUsage.limitType` is `"team"`, or `spendLimitUsage.pooledLimit` is present. Team accounts display Total usage in dollars; individual accounts display it as a percentage.

## Endpoints

### POST /aiserver.v1.DashboardService/GetCurrentPeriodUsage

Returns current billing cycle spend, limits, and percentage used.

#### Headers

| Header | Required | Value |
|---|---|---|
| Authorization | yes | `Bearer <access_token>` |
| Content-Type | yes | `application/json` |
| Connect-Protocol-Version | yes | `1` |

#### Request

```json
{}
```

#### Response

```jsonc
{
  "billingCycleStart": "1768399334000",   // unix ms (string)
  "billingCycleEnd": "1771077734000",
  "planUsage": {
    "totalSpend": 23222,                  // cents — includedSpend + bonusSpend
    "includedSpend": 23222,               // cents — counted against plan limit
    "bonusSpend": 0,                      // cents — free credits from model providers
    "remaining": 16778,                   // cents — limit minus includedSpend
    "limit": 40000,                       // cents — plan included amount
    "remainingBonus": false,              // true when bonus credits still available
    "bonusTooltip": "...",
    "autoPercentUsed": 0,                 // auto-mode usage %
    "apiPercentUsed": 46.444,             // API/manual usage %
    "totalPercentUsed": 15.48             // combined %
  },
  "spendLimitUsage": {                    // on-demand budget (after plan exhausted)
    "totalSpend": 0,                      // cents
    "pooledLimit": 50000,                 // cents — team pool (team plans only, optional)
    "pooledUsed": 0,
    "pooledRemaining": 50000,
    "individualLimit": 10000,             // cents — per-user cap
    "individualUsed": 0,
    "individualRemaining": 10000,
    "limitType": "user"                   // "user" | "team"
  },
  "displayThreshold": 200,               // basis points
  "enabled": true,
  "displayMessage": "You've used 46% of your usage limit",
  "autoModelSelectedDisplayMessage": "...",
  "namedModelSelectedDisplayMessage": "..."
}
```

### POST /aiserver.v1.DashboardService/GetPlanInfo

Returns plan name, price, and included amount.

#### Headers

Same as above.

#### Request

```json
{}
```

#### Response

```json
{
  "planInfo": {
    "planName": "Ultra",
    "includedAmountCents": 40000,
    "price": "$200/mo",
    "billingCycleEnd": "1771077734000"
  }
}
```

### POST /aiserver.v1.DashboardService/GetUsageLimitPolicyStatus

Returns whether user is in slow pool, feature gates, and allowed models. Response undocumented.

### POST /aiserver.v1.DashboardService/GetUsageLimitStatusAndActiveGrants

Returns limit policy status plus any active credit grants. Response undocumented.

## Authentication

### Token Sources

OpenUsage reads Cursor auth in this order:

1. **Cursor Desktop SQLite** (preferred)
2. **Cursor CLI keychain** (fallback)

#### 1) Cursor Desktop SQLite (preferred)

Path: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`

```bash
sqlite3 ~/Library/Application\ Support/Cursor/User/globalStorage/state.vscdb \
  "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
```

| Key | Description |
|---|---|
| `cursorAuth/accessToken` | JWT bearer token |
| `cursorAuth/refreshToken` | Token refresh credential |
| `cursorAuth/cachedEmail` | Account email |
| `cursorAuth/stripeMembershipType` | Plan tier (e.g. `pro`, `ultra`) |
| `cursorAuth/stripeSubscriptionStatus` | Subscription status |

#### 2) Cursor CLI keychain (fallback)

OpenUsage reads Cursor CLI tokens from keychain:

- `cursor-access-token`
- `cursor-refresh-token`

To initialize CLI auth:

```bash
agent login
```

### Token Refresh

Access tokens are short-lived JWTs. The app refreshes before each request if expired, then persists the new access token back to the same source it was loaded from (SQLite or keychain).

```
POST https://api2.cursor.sh/oauth/token
Content-Type: application/json
```

```json
{
  "grant_type": "refresh_token",
  "client_id": "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
  "refresh_token": "<refresh_token>"
}
```

**Success:**

```json
{
  "access_token": "<new_jwt>",
  "id_token": "<id_token>",
  "shouldLogout": false
}
```

**Invalid/expired token:**

```json
{
  "access_token": "",
  "id_token": "",
  "shouldLogout": true
}
```

When `shouldLogout` is `true`, the refresh token is invalid and the user must re-authenticate via Cursor.
