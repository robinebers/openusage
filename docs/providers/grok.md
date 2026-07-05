# Grok

Tracks Grok Build credit usage using the login from the Grok CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | The shared weekly pool's usage percent (the limit Grok's unified billing enforces), with the weekly reset countdown |
| Monthly | Credits used vs. your monthly limit |
| Extra Usage | Pay-as-you-go cap as a status (e.g. `2500 cap` or `Disabled`) |
| Today / Yesterday / Last 30 Days | Local cost and tokens estimated from the Grok CLI log |
| Plan | Your subscription tier (optional widget) |

Weekly and Monthly are different meters from different billing systems: the weekly shared pool is the rate limit Grok now enforces for unified-billing accounts, while the monthly credits meter tracks the older credit budget. Accounts that haven't been migrated to unified billing have no weekly pool, so the Weekly tile reads "No data" there.

## Where credentials come from

Sign in once with the Grok CLI (`grok login`); OpenUsage reads the same `~/.grok/auth.json`. Access tokens refresh automatically before expiry, and rotated tokens are written back to the file.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from the Grok CLI's log (`~/.grok/logs/unified.jsonl`, or `$GROK_HOME/logs/unified.jsonl`) — OpenUsage reads the log directly. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude/Codex/Cursor. The dollars are estimated from token counts at public API rates using the shared [model pricing](../pricing.md) (that's the ⓘ); the token counts themselves are measured, and these estimates are separate from the monthly credits the billing API reports. No log data leaves your Mac. A period with no recorded usage reads "No data" rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider.

## Troubleshooting

- **"Session expired" / auth errors** — run `grok login` again, then refresh.
- **"Weekly limit couldn't be updated"** (an amber warning on the Grok header) — the weekly-pool endpoint failed while everything else worked; the Weekly tile shows "No data" and the monthly meter and spend tiles keep updating. Usually transient; refresh again later.
- **Weekly shows "No data" without a warning** — your account still reports a monthly (non-weekly) period, meaning it hasn't been migrated to Grok's unified weekly billing yet.
- **Spend tiles show "No data"** — they need the Grok CLI's log at `~/.grok/logs/unified.jsonl`; older CLI versions logged no token counts. Run a Grok CLI session to populate it, then refresh.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing` for monthly usage and `…/v1/settings` for the plan name; token refresh via `auth.x.ai`. A 401/403 triggers one token refresh and retry.

The Weekly meter comes from `POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`, a gRPC-web (binary protobuf) endpoint that OpenUsage speaks with a small built-in codec. It serves grok.com's website rather than the CLI's own API (the CLI reaches the same backend over a WebSocket gateway), so it can change independently of the CLI — if it does, only the Weekly tile degrades (amber warning + "No data"); the rest of the provider is unaffected.
