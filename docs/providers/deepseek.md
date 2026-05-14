# DeepSeek

> Uses the DeepSeek user balance API with a user-provided API key and starting balance.

## Overview

- **Protocol:** HTTPS (JSON)
- **Endpoint:** `GET https://api.deepseek.com/user/balance`
- **Auth:** `Authorization: Bearer <api_key>`
- **Balance model:** remaining USD (or CNY) balance — no time-based limit

## Authentication

Set the following environment variables:

| Variable | Required | Description |
|---|---|---|
| `DEEPSEEK_API_KEY` | yes | DeepSeek API key from [platform.deepseek.com](https://platform.deepseek.com/) |
| `DEEPSEEK_INITIAL_BALANCE` | yes | Your starting balance (e.g. `10.00`). Must be > 0. |

If any variable is missing or invalid, the plugin throws:

- `DeepSeek API key missing. Set DEEPSEEK_API_KEY.`
- `DeepSeek initial balance missing or invalid. Set DEEPSEEK_INITIAL_BALANCE to your starting balance (e.g. 10.00).`

## Data Source

Request:

```http
GET /user/balance HTTP/1.1
Host: api.deepseek.com
Authorization: Bearer <api_key>
Accept: application/json
```

Response:

```jsonc
{
  "is_available": true,
  "balance_infos": [
    {
      "currency": "USD",           // "USD" or "CNY"
      "total_balance": "3.55",     // string, parse as float
      "granted_balance": "0.00",   // non-expired granted balance
      "topped_up_balance": "3.55"  // topped-up balance
    }
  ]
}
```

## Usage Mapping

- Prefer the `USD` entry in `balance_infos`. Fall back to `CNY` if no USD entry is present.
- `used = DEEPSEEK_INITIAL_BALANCE − total_balance` (clamped to ≥ 0).
- `limit = DEEPSEEK_INITIAL_BALANCE`.
- No reset timestamp — balance is a lifetime metric, not a periodic window.
- Plan name is not reported by this API.

## Output

- **Balance** (overview progress line):
  - `label`: `Balance`
  - `format`: dollars (shown as `$X.XX / $Y.YY`)
  - `used`: dollars spent (initial − remaining)
  - `limit`: initial balance set by user

## Errors

| Condition | Message |
|---|---|
| Missing API key | `DeepSeek API key missing. Set DEEPSEEK_API_KEY.` |
| Missing/invalid initial balance | `DeepSeek initial balance missing or invalid. Set DEEPSEEK_INITIAL_BALANCE to your starting balance (e.g. 10.00).` |
| HTTP 401/403 | `Session expired. Check your DeepSeek API key.` |
| Non-2xx | `Request failed (HTTP {status}). Try again later.` |
| Network failure | `Request failed. Check your connection.` |
| Unparseable response | `Could not parse usage data.` |
| No USD/CNY balance in response | `Could not find balance in response.` |
