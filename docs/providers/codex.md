# Codex

Tracks your ChatGPT/Codex subscription limits using the login from the Codex CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Spark / Spark Weekly | GPT-5.3-Codex-Spark model limits — a 5-hour and a weekly window. Shown only when your account has the limit (otherwise "No data"), and tucked below the "show more" caret by default |
| Rate Limit Resets | On-demand rate-limit reset credits, shown as a count (e.g. `2 available`) with a colored dot for the soonest expiry; hover the value for a timeline of each credit's expiry |
| Extra Usage | Flex credits, shown verbatim as dollars + credits (e.g. `$31.84 · 796 credits`) |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Sign in once with the Codex CLI (`codex`); OpenUsage reads the same auth files (`$CODEX_HOME` respected) with a keychain fallback. Tokens refresh automatically and rotate back into the auth file.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally**: OpenUsage reads the Codex CLI's session rollouts under `~/.codex/sessions/` and `archived_sessions/` (or `$CODEX_HOME`) itself — no external tools needed. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); if your `config.toml` requests the fast/priority service tier, the fast rates apply. The token counts themselves are measured. No log data leaves your Mac.

## Troubleshooting

- **"Not logged in"** — run `codex` and sign in, then refresh.
- **API-key-only setups** can't read subscription usage — sign in with your ChatGPT account instead.
- **Spend tiles show "No data"** — OpenUsage found no Codex session logs in the last 30 days. If your Codex home lives somewhere custom, set `CODEX_HOME` so both the Codex CLI and OpenUsage look in the same place.

## Under the hood

`GET https://chatgpt.com/backend-api/wham/usage` with the Codex OAuth token; refresh via `auth.openai.com`. A 401/403 triggers one token refresh and retry. Session and Weekly are read from the usage window in that response, with the response headers used only when the window fields are missing.

Spark and Spark Weekly come from the same response's `additional_rate_limits` array — model-specific limits that reuse the Session/Weekly window shape. OpenUsage surfaces the entry whose name identifies GPT-5.3-Codex-Spark as those two meters; accounts without the limit simply omit the entry, so the rows read "No data". Other model limits in that array aren't shown.

OpenUsage preserves Codex's reported `used_percent` verbatim. If the API reports 1% used for an untouched window, the app shows 99% left; if it reports 0%, the app shows 100% left. Codex rows use the normal reset label rather than inferring a special "Not started" state. Burn-rate pacing still waits until enough of the window has elapsed to make a useful projection.

The "Rate Limit Resets" row shows the on-demand reset-credit count, e.g. `2 available`, with a colored dot for the soonest credit's expiry — blue beyond a week, yellow within a week, red within 48 hours. OpenUsage also makes a best-effort `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` call — the dedicated endpoint that lists each credit's expiry — and surfaces those in a popover when you hover the value: a timeline of each reset, soonest-first — a numbered color dot, the exact expiry time (`Jul 12 at 5:30 PM`), and the countdown to it (`12d 18h`) on the trailing edge. When no credits are available it reads `0 available` and the popover shows `You have no rate limit resets`. If the dedicated call fails, the row falls back to the count embedded in the usage body (`rate_limit_reset_credits.available_count`); since that body carries no per-credit expiries, the popover states the count (`N available`) and notes that expiry times are unavailable rather than implying there are none.
