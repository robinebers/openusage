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

## Spend history (temporarily unavailable)

Cursor's per-day spend tiles (Today / Yesterday / Last 30 Days) and the Usage Trend chart are **turned off for now**. They were built from Cursor's server-side usage export, which has started reporting at least ~12 hours behind real time — so a day's cost and tokens would show up stale or empty (for example, a `$0.00` "Today" while you're actively using Cursor). Rather than show misleading numbers, OpenUsage hides these rows until Cursor's reporting catches up. Everything else (Total / Auto / API usage, Extra Usage, Credits) is live and unaffected.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type (e.g. Requests only exists on request-based accounts); missing metrics simply show "No data".

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage), REST fallback at `cursor.com/api/usage` for request-based accounts, and Stripe balance at `cursor.com/api/auth/stripe`. A 401/403 triggers one token refresh and retry. (The usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv` previously fed the spend history; it's not currently fetched — see above.)
