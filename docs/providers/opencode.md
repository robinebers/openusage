# OpenCode

Tracks your OpenCode-hosted usage — the **Go** subscription and the **Zen** pay-as-you-go gateway. Go
plan windows come from OpenCode's official usage API. Spend tiles and the usage trend still come from
OpenCode's logs already on your Mac.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Go usage in the rolling 5-hour window, as a percent, with the reset countdown |
| Weekly | Go usage this week, as a percent (resets Monday UTC) |
| Monthly | Go usage this billing cycle, as a percent |
| Today / Yesterday / Last 30 Days | Local cost and tokens across all your OpenCode-hosted usage (Go + Zen) |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

When you have the Go subscription, OpenUsage shows "Go" beside the provider name.

The Session / Weekly / Monthly meters are **account-wide** — the same percents the OpenCode dashboard
shows, including usage from other machines. If you only use the Zen pay-as-you-go gateway (no Go
subscription), the cap meters are hidden and you'll just see the spend tiles.

## Where credentials come from

Use OpenCode as usual. OpenUsage reads the `opencode-go` API key from OpenCode's local data directory
(`~/.local/share/opencode`, or `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME` if you've set them) and
sends it as a Bearer token to the usage API. There's no login prompt and no token to paste.

OpenCode 1 stored the key in `auth.json` (`{"opencode-go":{"key":"sk-..."}}`); OpenCode 2 (beta)
stores it in the SQLite `credential` table (`integration_id='opencode-go'`, `value` JSON
`{"type":"key","key":"sk-..."}`). OpenUsage tries `auth.json` first, then falls back to the
`credential` table so fresh installs after 2026 still get Go meters. Spend tiles still read the
local SQLite logs in that same directory.

## The meters and spend tiles

Go meters are percents from `GET https://opencode.ai/zen/go/v1/usage` — OpenCode's own accounting, not
an estimate. Each spend tile shows cost and tokens together (`$4.08 · 1.2M tokens`), the same as Claude /
Codex / Cursor. Those dollars come straight from the per-message cost OpenCode records for its hosted
gateways on this Mac, so they can be lower than account-wide Go usage. A period with no recorded local
usage reads "No data" rather than a misleading `$0.00`. No log data leaves your Mac.

## Troubleshooting

- **No Session / Weekly / Monthly meters** — those are Go-plan windows. You'll see them when you're
  logged into OpenCode Go (`opencode-go` in `auth.json` or the `credential` table) and the key has an
  active subscription. Zen-only users see the spend tiles instead.
- **"OpenCode Go key was rejected"** — the local key was not accepted. Log into OpenCode Go again so
  the credential is rewritten (either `auth.json` or the `credential` table).
- **"No OpenCode Go subscription on this key"** — the key is valid but this account isn't on Go. The
  spend tiles still work if you use Zen locally.
- **"Couldn't read OpenCode's auth.json"** — the file exists but is unreadable or not valid JSON. Check
  its permissions, or log into OpenCode Go again to rewrite it. On OpenCode 2 the key may live in
  `opencode.db`'s `credential` table instead, so this error only appears when `auth.json` is present but broken.
- **Spend tiles show "No data"** — OpenUsage needs OpenCode's local database at
  `~/.local/share/opencode/opencode*.db`. Run an OpenCode session, then refresh.
- **"Couldn't read OpenCode's local database"** — the database (or data directory) exists but couldn't be
  read this refresh. If you're on Go, the percent meters still refresh; quit OpenCode and refresh to
  restore the tiles. If it persists, check the permissions on `~/.local/share/opencode`.

## Under the hood

Go windows: `GET https://opencode.ai/zen/go/v1/usage` with the `opencode-go` key as `Authorization:
Bearer …`. The response is `{ usage: { rolling, weekly, monthly } }`, each with `percent` and
`resetsAt`. A 401 is a rejected key; a 403 `EntitlementError` means no Go subscription.

Spend tiles and trend: assistant-message `cost` and token fields from every `opencode*.db` in the data
directory (OpenCode partitions its database by release channel — stable is `opencode.db`, the preview
line is `opencode-next.db` — so all channels are unioned). OpenCode 1 logged to the `message` table
(`$.role`, `$.providerID`, `$.modelID`, `$.tokens.total`); OpenCode 2 logs to `session_message`
(`type='assistant'`, `$.model.providerID`, `$.model.id`, `$.tokens.input/output/reasoning/cache.*`). The
query unions both tables with coalesced JSON paths so either schema (or both during migration) works.
Both `opencode-go` (Go) and `opencode` (Zen) count. Read-only.
