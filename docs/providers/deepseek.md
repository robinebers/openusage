# DeepSeek

Tracks the remaining balance of your DeepSeek API account, including paid and granted credits.

## What it tracks

| Metric | Meaning |
|---|---|
| Balance | Total available balance (`total_balance`) |
| Paid | Remaining topped-up balance (`topped_up_balance`) |
| Granted | Remaining, unexpired granted balance (`granted_balance`) |

USD is preferred when DeepSeek returns both USD and CNY. A CNY-only account shows amounts with an
explicit `CNY` label; currencies are never added together or converted. A measured zero displays as
zero. These are unbounded balances, so there is no quota meter or reset countdown.

All three metrics are enabled by default, in the order above. Balance is Always Visible; Paid and
Granted are On Demand. None are pinned to the menu bar by default.

If DeepSeek reports `is_available: false`, OpenUsage keeps the returned balances and shows a warning
that they are unavailable for API calls. This also applies when the returned balance is positive.

## Setup

Create an API key at [DeepSeek Platform](https://platform.deepseek.com/api_keys), then open
**Customize → DeepSeek → API Key**, paste the key, and Save. Enable the provider in Customize if needed.
The key is stored at `~/.config/openusage/deepseek.json` and used on the next refresh:

```json
{ "apiKey": "sk-..." }
```

The auth store reads this file first, then `DEEPSEEK_API_KEY`, then `DEEPSEEK_KEY`. A saved key overrides
an environment key; clearing it falls back to the environment. JSON fields `api_key` and `key`, or a
plain-text key file at the same path, also work. Export environment keys in your login shell profile
so Finder-launched builds can read them.

You can use the same DeepSeek API key that you configured in CodexBar. OpenUsage does not import
CodexBar's config or browser sessions. A DeepSeek Platform session token is not an API key.

## Under the hood

One request to DeepSeek's [public balance endpoint](https://api-docs.deepseek.com/api/get-user-balance):

- `GET https://api.deepseek.com/user/balance`
- `Authorization: Bearer <API key>`
- `Accept: application/json`

The endpoint reports account balances and availability, not daily/monthly spend, token counts,
requests, or session/weekly quotas. This provider does not call private dashboard endpoints.

The local API and CLI export `balance`, `paid`, and `granted` as balance resources, with `available`
amounts and the reported `usd` or `cny` unit.

## Troubleshooting

- **No DeepSeek API key** — add a key in Customize or export one of the environment variables above.
- **DeepSeek API key invalid** — the API rejected the key (401/403); check or replace it in DeepSeek Platform.
- **Balance unavailable for API calls** — DeepSeek returned `is_available: false`; check your account and credits.
- **DeepSeek balance data unavailable** — the response was empty, malformed, or missing valid balance fields.
- **DeepSeek returned no USD or CNY balance** — the API returned an unsupported currency.
- Other network or HTTP failures appear as provider errors; OpenUsage does not replace them with a zero balance.
