# Codex

Tracks your ChatGPT/Codex subscription limits using the login from the Codex CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Spark / Spark Weekly | GPT-5.3-Codex-Spark model limits — a 5-hour and a weekly window. Shown only when your account has the limit (otherwise "No data"), and tucked below the "show more" caret by default |
| Rate Limit Resets | On-demand rate-limit reset credits, shown as a count (e.g. `2 available`); hover for each credit's expiry, with a warning triangle when one is about to expire |
| Extra Usage | Flex credits, shown verbatim as dollars + credits (e.g. `$31.84 · 796 credits`) |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Sign in once with the Codex CLI (`codex`); OpenUsage reads the same auth files (`$CODEX_HOME` respected) with a keychain fallback. Tokens refresh automatically and rotate back into the auth file.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally** from your Codex logs by running `ccusage` through whichever JavaScript package runner you already have — [Bun](https://bun.sh) (`bunx`) is preferred, otherwise `pnpm dlx`, `yarn dlx`, `npm exec`, or `npx`. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts (that's the ⓘ); the token counts themselves are measured. No log data leaves your Mac.

## Troubleshooting

- **"Not logged in"** — run `codex` and sign in, then refresh.
- **API-key-only setups** can't read subscription usage — sign in with your ChatGPT account instead.
- **Spend tiles show "No data"** — OpenUsage needs a package runner on its `PATH` to run `ccusage`. Install [Bun](https://bun.sh), or make sure `npx`/`npm` is available (any Node.js install). If you use a version manager (nvm, fnm, volta), OpenUsage looks in the common locations, but a global Bun or Node install is the most reliable.

## Under the hood

`GET https://chatgpt.com/backend-api/wham/usage` with the Codex OAuth token; refresh via `auth.openai.com`. A 401/403 triggers one token refresh and retry. Session and Weekly are read from the usage window in that response, with the response headers used only when the window fields are missing.

Spark and Spark Weekly come from the same response's `additional_rate_limits` array — model-specific limits that reuse the Session/Weekly window shape. OpenUsage surfaces the entry whose name identifies GPT-5.3-Codex-Spark as those two meters; accounts without the limit simply omit the entry, so the rows read "No data". Other model limits in that array aren't shown.

When a rolling window still has a full period left before reset (`reset_after_seconds` ≈ `limit_window_seconds`), OpenUsage treats it as a fresh window: a `used_percent` of 0–1% is normalized to unused (Codex’s whole-percent floor), and burn-rate pacing waits until the window has materially started before projecting. While the current Session window has no usage, the Session row reads **Not started** on the trailing label, and the hover explains that the session begins after your first message.

The "Rate Limit Resets" row shows the on-demand reset-credit count, e.g. `2 available`. OpenUsage also makes a best-effort `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` call — the dedicated endpoint that lists each credit's expiry — and surfaces those on hover (`Reset expires in 12d 18h`, or a numbered `Resets expire in:` list for several), following the global relative/absolute time setting. A warning triangle appears beside the count when the soonest credit is within 24 hours of expiring. If that call fails, the row falls back to the count embedded in the usage body (`rate_limit_reset_credits.available_count`) with no expiry tooltip. An empty balance reads `0 available`.
