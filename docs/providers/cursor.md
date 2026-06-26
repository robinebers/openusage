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
| Today / Yesterday / Last 30 Days | Per-day cost and tokens from Cursor's own usage export |
| Models | Per-model usage leaderboard for the last 30 days (optional widget) |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Just be signed into the Cursor app. OpenUsage reads Cursor's local state database (and its keychain entries) for the session tokens; refreshed tokens are persisted back. Nothing extra to install or configure.

## The spend tiles

Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude/Codex/Grok; a day with no usage is a real zero and reads `$0.00 · 0 tokens`. The difference is the source: Cursor's Today / Yesterday / Last 30 Days come from Cursor's **server-side usage export** (priced per model with a bundled price list), not a local estimate. Hover the value to see the exact figures and source note. If the export can't be fetched, the tiles show "No data" while everything else keeps working.

## The models leaderboard

The optional **Models** widget ranks the models you've used over the last 30 days by spend, from the same usage export the spend tiles use. The row stays compact — the top three model names, numbered by rank — and hovering reveals the full list with each model's spend and token count. Models are grouped by family (a model's faster and reasoning variants count as one). Anything under 3% of your spend is grouped into a single "Other" row; a model Cursor hasn't priced is kept on its own, shown with a dash for cost and a small warning marker. Like the spend tiles, the per-model dollars are imputed from token counts at base rates, so they're an estimate.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type (e.g. Requests only exists on request-based accounts); missing metrics simply show "No data".

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage), REST fallback at `cursor.com/api/usage` for request-based accounts, Stripe balance at `cursor.com/api/auth/stripe`, and the CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. A 401/403 triggers one token refresh and retry.
