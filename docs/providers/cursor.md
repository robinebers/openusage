# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Credit balance used vs. your grant + prepaid balance |
| Total Usage | Plan usage for the billing cycle (percent; dollars on team plans) |
| Requests | Request count vs. cap (team/enterprise accounts) |
| Auto Limits | Auto-model usage percent |
| API Usage | API usage percent |
| Extra Usage | On-demand spend vs. its limit |
| Today / Yesterday / Last 30 Days | Per-day cost and tokens from Cursor's own usage export |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Just be signed into the Cursor app. OpenUsage reads Cursor's local state database (and its keychain entries) for the session tokens; refreshed tokens are persisted back. Nothing extra to install or configure.

## The spend tiles

Each period is one tile showing cost and tokens together (`$4.08 · 1.2M`), the same as Claude/Codex/Grok. The difference is the source: Cursor's Today / Yesterday / Last 30 Days come from Cursor's **server-side usage export** (priced per model with a bundled price list), not a local estimate — so the dollars carry no ⓘ. If the export can't be fetched, the tiles show "No data" while everything else keeps working.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type (e.g. Requests only exists on request-based accounts); missing metrics simply show "No data".

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage), REST fallback at `cursor.com/api/usage` for request-based accounts, Stripe balance at `cursor.com/api/auth/stripe`, and the CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. A 401/403 triggers one token refresh and retry.
