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

Today / Yesterday / Last 30 Days are computed **locally**: OpenUsage reads the Claude Code session logs under `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR`) itself — no external tools needed. Symlinks are followed, so a projects folder linked into a synced location (say, a Dropbox folder) is read all the same. Cowork (the Claude desktop app's agent mode) counts too: it writes the same logs into per-session folders under `~/Library/Application Support/Claude/local-agent-mode-sessions/`, and OpenUsage scans those as well, so desktop agent sessions show up in the tiles alongside terminal ones. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage reads **No data** rather than a misleading `$0.00 · 0 tokens` — the same as every other spend-tracking provider. The live Session and Weekly meters are unaffected. The dollars are estimated from token counts at API rates (that's the ⓘ) using the shared [model pricing](../pricing.md); the token counts themselves are measured. No log data leaves your Mac.

## Multiple accounts

If you're signed in to more than one Claude account on this Mac, the Claude card grows a small picker beside the provider name (the caret, like the Total Spend card's metric switch). Pick an account to swap the whole card — and any Claude metrics you've pinned to the menu bar — to that login's numbers. Nothing else changes: your metric layout, stars, and provider order are shared, only the data swaps.

- Extra accounts are found automatically at launch by listing the Claude Code entries in your keychain (each `CLAUDE_CONFIG_DIR` login is its own entry) — no setup, nothing on disk is searched, and no secret is read until the account is actually refreshed. A newly added login shows up the next time OpenUsage launches. The first refresh of an extra account can show macOS's usual one-time keychain permission dialog, once per account — the same dialog your main login showed.
- Rename or remove an extra account in Customize → Claude → **Accounts**. Renames apply immediately everywhere the name shows. Removing an account only makes OpenUsage forget it — the login itself is untouched, and one that still exists is found again on a later launch.
- The spend tiles (Today / Yesterday / Last 30 Days) and the usage trend come from the session logs on this Mac, which belong to your default setup — so they show real numbers on the default account and **No data** while an extra account is selected.

## Troubleshooting

- **"Not logged in"** — run `claude` and sign in, then refresh.
- **"Signed in to the Claude desktop app?"** — a login done only in the Claude desktop app is stored encrypted in a way OpenUsage can't read. Run `claude` in a terminal and sign in once; both logins coexist, and OpenUsage picks up the CLI one.
- **"Re-login for live usage"** (an amber warning on the Claude header) — your saved login can authenticate for inference but can't read your subscription limits, because it lacks the `user:profile` access (this is what an inference-only token from `claude setup-token` carries). Run `claude` and sign in again with your Claude account, then refresh; the spend tiles keep working in the meantime.
- **"Updates blocked by Anthropic"** (an amber warning on the Claude header) — the usage API is throttling OpenUsage. It keeps the last values from the same login, shows when it will retry, and backs off in the meantime. A different login starts with a fresh cache and cooldown.
- **Spend tiles show "No data"** — OpenUsage found no Claude Code logs in the last 30 days. If your logs live somewhere custom, set `CLAUDE_CONFIG_DIR` so both Claude Code and OpenUsage look in the same place.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token; refresh via `platform.claude.com/v1/oauth/token`. A 401/403 triggers one token refresh and retry. If that still fails because the token is expired or revoked, OpenUsage retries with the next credential source before reporting an error.

When the five-hour session window has no usage yet, the Session row shows **Not started** on the trailing label; hover explains that the session begins after your first message.
