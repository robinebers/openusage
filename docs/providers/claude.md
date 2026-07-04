# Claude

Tracks your Claude subscription limits using the login you already have from Claude Code.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Sonnet | Separate weekly Sonnet limit (plan-dependent) |
| Fable | Separate weekly Fable limit (model-scoped window from the `limits` array) |
| Extra Usage | Extra-usage credits spent against your monthly cap |
| Today / Yesterday / Last 30 Days | Local spend, as cost, tokens, or both (see below) |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Sign in once with Claude Code; OpenUsage reads the same credentials. It checks every place Claude Code can store them, in priority order — the keychain is Claude Code's source of truth on macOS, so it wins over a leftover credentials file:

1. `CLAUDE_CODE_OAUTH_TOKEN` environment variable
2. The macOS keychain entry Claude Code maintains
3. `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)

If one source holds an expired or "locked out" token, OpenUsage falls back to the others — so signing in again with `claude` outside the app is picked up on the next refresh, without restarting OpenUsage. Tokens are refreshed automatically; rotated tokens are written back where they came from.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally**: OpenUsage reads the Claude Code session logs under `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`) itself — no external tools needed. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); the token counts themselves are measured. No log data leaves your Mac.

## Troubleshooting

- **"Not logged in"** — run `claude` and sign in, then refresh.
- **"Signed in to the Claude desktop app?"** — a login done only in the Claude desktop app is stored encrypted in a way OpenUsage can't read. Run `claude` in a terminal and sign in once; both logins coexist, and OpenUsage picks up the CLI one.
- **"Re-login for live usage"** (an amber warning on the Claude header) — your saved login can authenticate for inference but can't read your subscription limits, because it lacks the `user:profile` access (this is what an inference-only token from `claude setup-token` carries). Run `claude` and sign in again with your Claude account, then refresh; the spend tiles keep working in the meantime.
- **"Updates blocked by Anthropic"** (an amber warning on the Claude header) — the usage API is throttling OpenUsage. It keeps your last values, shows when it will retry, and backs off in the meantime — manual refreshes only extend the block, so the best fix is patience.
- **Spend tiles show "No data"** — OpenUsage found no Claude Code logs in the last 30 days. If your logs live somewhere custom, set `CLAUDE_CONFIG_DIR` so both Claude Code and OpenUsage look in the same place.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token; refresh via `platform.claude.com/v1/oauth/token`. A 401/403 triggers one token refresh and retry. If that still fails because the token is expired or revoked, OpenUsage retries with the next credential source before reporting an error.

When the five-hour session window has no usage yet, the Session row shows **Not started** on the trailing label; hover explains that the session begins after your first message.
