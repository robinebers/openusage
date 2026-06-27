# Claude

Tracks your Claude subscription limits using the login you already have from Claude Code.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage |
| Weekly | 7-day window usage |
| Sonnet | Separate weekly Sonnet limit (plan-dependent) |
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

Today / Yesterday / Last 30 Days are computed **locally** from your Claude Code logs by running `ccusage` through whichever JavaScript package runner you already have — [Bun](https://bun.sh) (`bunx`) is preferred, otherwise `pnpm dlx`, `yarn dlx`, `npm exec`, or `npx`. Days are grouped in your Mac's local time zone, so they line up with your own calendar. Each period is one tile showing cost and tokens together (`$4.08 · 1.2M tokens`); a day with no usage is a real zero and reads `$0.00 · 0 tokens`. If `ccusage` hasn't reported a recent day yet — it can briefly lag a Claude Code update — Today / Yesterday read **No data** instead of a misleading `$0.00`; the live Session and Weekly meters are unaffected. The dollars are estimated from token counts (that's the ⓘ); the token counts themselves are measured. No log data leaves your Mac.

## Troubleshooting

- **"Not logged in"** — run `claude` and sign in, then refresh.
- **"Rate limited, retry in ~Nm"** — the usage API is throttling; OpenUsage shows when to expect data again and keeps your last values.
- **Spend tiles show "No data"** — OpenUsage needs a package runner on its `PATH` to run `ccusage`. Install [Bun](https://bun.sh) (`curl -fsSL https://bun.sh/install | bash`), or make sure `npx`/`npm` is available (any Node.js install). If you use a version manager (nvm, fnm, volta), OpenUsage looks in the common locations, but a global Bun or Node install is the most reliable.

## Under the hood

`GET https://api.anthropic.com/api/oauth/usage` with the Claude Code OAuth token; refresh via `platform.claude.com/v1/oauth/token`. A 401/403 triggers one token refresh and retry. If that still fails because the token is expired or revoked, OpenUsage retries with the next credential source before reporting an error.

When the five-hour session window has no usage yet, the Session row shows **Not started** on the trailing label; hover explains that the session begins after your first message.
