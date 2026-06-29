# Grok

Tracks Grok Build credit usage using the login from the Grok CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Monthly | Credits used vs. your monthly limit |
| Extra Usage | Pay-as-you-go cap as a status (e.g. `2500 cap` or `Disabled`) |
| Today / Yesterday / Last 30 Days | Local cost and tokens estimated from the Grok CLI log |
| Plan | Your subscription tier (optional widget) |

## Where credentials come from

Sign in once with the Grok CLI (`grok login`); OpenUsage reads the same `~/.grok/auth.json`. Access tokens refresh automatically before expiry, and rotated tokens are written back to the file.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from the Grok CLI's log (`~/.grok/logs/unified.jsonl`, or `$GROK_HOME/logs/unified.jsonl`). Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude/Codex/Cursor. Unlike Claude/Codex this needs no package runner — OpenUsage reads the log directly. The dollars are estimated from token counts at public API rates (that's the ⓘ); the token counts themselves are measured, and these estimates are separate from the monthly credits the billing API reports. No log data leaves your Mac. A period with no recorded usage reads "No data" rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider.

## Troubleshooting

- **"Session expired" / auth errors** — run `grok login` again, then refresh.
- **Spend tiles show "No data"** — they need the Grok CLI's log at `~/.grok/logs/unified.jsonl`; older CLI versions logged no token counts. Run a Grok CLI session to populate it, then refresh.

## Under the hood

`GET https://cli-chat-proxy.grok.com/v1/billing` for usage and `…/v1/settings` for the plan name; token refresh via `auth.x.ai`. A 401/403 triggers one token refresh and retry.
