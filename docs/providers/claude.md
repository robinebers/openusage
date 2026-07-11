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

When Claude reports your plan name, OpenUsage shows it beside the provider name.

## Where credentials come from

Sign in once with Claude Code; OpenUsage reads the same credentials. It checks every place Claude Code can store them, preferring the login that can actually read your subscription usage:

1. The macOS keychain entry Claude Code maintains (its source of truth on macOS)
2. `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR/.credentials.json`)
3. `CLAUDE_CODE_OAUTH_TOKEN` environment variable

A `CLAUDE_CODE_OAUTH_TOKEN` — usually a long-lived `claude setup-token` — can run the model but can't read your Session and Weekly limits, and it often lingers in your shell environment. So when a real keychain or file login is present, OpenUsage uses that login for the live meters and keeps the environment token only as a fallback; the Session/Weekly meters no longer go blank just because that token is set. If the environment token is your *only* credential (a headless setup), it's used on its own and the spend tiles still load from local logs.

If one source holds an expired or "locked out" token, OpenUsage falls back to the others — so signing in again with `claude` outside the app is picked up on the next refresh, without restarting OpenUsage. Tokens are refreshed automatically; rotated tokens are written back only while the ordered login candidates still match the start of the refresh, so a newly added higher-priority login wins.

## The spend tiles

Today / Yesterday / Last 30 Days are computed **locally**: OpenUsage reads the Claude Code session logs under `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`) itself — no external tools needed. Cowork (the Claude desktop app's agent mode) counts too: it writes the same logs into per-session folders under `~/Library/Application Support/Claude/local-agent-mode-sessions/`, and OpenUsage scans those as well, so desktop agent sessions show up in the tiles alongside terminal ones. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); the token counts themselves are measured. No log data leaves your Mac.

## Multiple accounts

If you sign in to more than one Claude account on the same Mac, OpenUsage shows each as its own card. It finds the extra accounts automatically at launch — no setup — by looking one level deep: your default `~/.claude`, any sibling `~/.claude*` folder that has credentials, `$XDG_CONFIG_HOME/claude`, anything in `CLAUDE_CONFIG_DIR`, and the Claude Code entries in your keychain. Nothing on disk is searched beyond those spots.

- Your primary account is the usual **Claude** card. Each additional account gets its own card, named `Claude (########)` until you rename it (open Customize, tap the account, and set an **Account Name**). Renames apply right away, everywhere the account name shows.
- Extra accounts show the live meters only — Session, Weekly, Sonnet, Fable, and Extra Usage. They don't show the local spend tiles (Today / Yesterday / Last 30 Days) or the usage trend, because those come from local logs that can't be split per account; the spend tiles stay on the primary Claude card and still cover all your usage.
- A new account you add is picked up the next time OpenUsage launches. Removing an account's credentials leaves its card in place showing "Not logged in" rather than silently dropping your layout.

## Troubleshooting

- **"Not logged in"** — run `claude` and sign in, then refresh.
- **"Signed in to the Claude desktop app?"** — a login done only in the Claude desktop app is stored encrypted in a way OpenUsage can't read. Run `claude` in a terminal and sign in once; both logins coexist, and OpenUsage picks up the CLI one.
- **"Re-login for live usage"** (an amber warning on the Claude header) — your saved login can authenticate for inference but can't read your subscription limits, because it lacks the `user:profile` access (this is what an inference-only token from `claude setup-token` carries). Run `claude` and sign in again with your Claude account, then refresh; the spend tiles keep working in the meantime.
- **"Updates blocked by Anthropic"** (an amber warning on the Claude header) — the usage API is throttling OpenUsage. It keeps the last values from the same login, shows when it will retry, and backs off in the meantime. A different login starts with a fresh cache and cooldown.
- **Spend tiles show "No data"** — OpenUsage found no Claude Code logs in the last 30 days. If your logs live somewhere custom, set `CLAUDE_CONFIG_DIR` so both Claude Code and OpenUsage look in the same place.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token; refresh via `platform.claude.com/v1/oauth/token`. A 401/403 triggers one token refresh and retry. If that still fails because the token is expired or revoked, OpenUsage retries with the next credential source before reporting an error.

When the five-hour session window has no usage yet, the Session row shows **Not started** on the trailing label; hover explains that the session begins after your first message.
