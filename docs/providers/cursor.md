# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Credit balance left from grants and prepaid account balance |
| Total Usage | Plan usage for the billing cycle (percent; dollars on team plans) |
| Requests | Request count vs. cap (team/enterprise accounts) |
| Auto Usage | Auto-model usage percent |
| API Usage | API usage percent |
| Extra Usage | On-demand spend; shown as a meter only when Cursor returns a limit |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Just be signed into the Cursor app. OpenUsage reads Cursor's local state database (and its keychain entries) for the session tokens; refreshed tokens are persisted back. Nothing extra to install or configure.

## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage export. OpenUsage uses the exported token counts and shared model pricing to estimate the cost locally. Cursor's export may occasionally arrive late, so the newest figures can lag behind current activity.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type (e.g. Requests only exists on request-based accounts); missing metrics simply show "No data".

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage), REST fallback at `cursor.com/api/usage` for request-based accounts, and Stripe balance at `cursor.com/api/auth/stripe`. A 401/403 triggers one token refresh and retry. Per-day spend imputation uses token counts priced through the shared [model pricing](../pricing.md); Cursor-native models (`auto`, `composer-*`, …) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md). (The usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv` previously fed the spend history; it's not currently fetched — see above.)
