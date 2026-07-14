# OpenCode

Tracks every model you use through OpenCode — including **ChatGPT OAuth**, Hugging Face, other external
providers, the **Go** subscription, and the **Zen** pay-as-you-go gateway — from OpenCode's own logs already
on your Mac. Raw logs and credentials stay local; normalized history syncs through your private iCloud
container only when you enable Sync Across Macs.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | Go spend in the rolling 5-hour window, against the $12 cap, with the reset countdown |
| Weekly | Go spend this week, against the $30 cap (resets Monday) |
| Monthly | Go spend this cycle, against the $60 cap |
| Today / Yesterday / Last 30 Days | Local tokens with a recorded or estimated API-rate cost across every provider used through OpenCode |
| Usage Trend | A day-by-day sparkline of tokens over the last month |

When you have the Go subscription, OpenUsage shows "Go" beside the provider name.

The Session / Weekly / Monthly meters show **observed local spend** — the usage recorded on *this* Mac. If
you also use OpenCode Go on another machine, or OpenCode hasn't finished writing a session locally, the
local figure can be lower than your true account usage, so treat the caps as a guide rather than the last
word. (When OpenCode ships an official usage API, OpenUsage can switch to authoritative numbers without any
change on your side.) If you only use the Zen pay-as-you-go gateway (no Go subscription), the cap meters are
hidden and you'll just see the spend tiles.

## Where credentials come from

Use OpenCode as usual and sign in to whichever providers you want there. OpenUsage reads OpenCode's local data directory
(`~/.local/share/opencode`, or `$OPENCODE_DATA_DIR` / `$XDG_DATA_HOME` if you've set them): the
non-secret presence of provider logins in `auth.json`, the Go key when present, and the local SQLite logs
for the numbers. External credentials are never returned, logged, or sent anywhere. There's no OpenUsage
login prompt and no token to paste.

## The meters and spend tiles

Tokens come straight from OpenCode's completed assistant messages. OpenCode derives positive costs
from model metadata, so OpenUsage keeps those API-rate values and marks them estimated. Some
subscription-backed logins such as ChatGPT OAuth record `$0` even though they carry full token counts;
OpenUsage prices those buckets through the same shared catalog as Codex. This is an **API-rate value**, not
money charged on top of your subscription. Because each completed OpenCode message preserves its token
buckets, model-specific long-context pricing can be applied per request. OpenCode-specific model aliases
and provider spellings are normalized before catalog lookup. When a model has no known rate, its usage is excluded from the
token and dollar totals and the warning triangle names it, rather than showing mismatched figures. If
none of the usage can be priced, the provider warning still names the affected models.

Each spend tile shows cost and the corresponding priced tokens together (`$4.08 · 1.2M tokens`). A period
where nothing can be priced reads "No data".
No log data leaves your Mac.

The Go caps OpenUsage draws against are the published plan limits: **$12 per rolling 5 hours**, **$30 per
week** (UTC Monday), and **$60 per month** (the monthly cycle is anchored to the day of the month you first
used Go). Zen usage is pay-as-you-go credits with no cap, so it appears only in the spend tiles.

## Troubleshooting

- **Everything shows "No data"** — OpenUsage needs OpenCode's local database at
  `~/.local/share/opencode/opencode*.db`. Run an OpenCode session, then refresh. (If you're logged into
  Go, the cap meters show at $0 even before your first local message.)
- **No Session / Weekly / Monthly meters** — those are Go-plan caps; you'll see them when you're logged
  into OpenCode Go or have used it recently on this Mac. Zen-only (or lapsed) users see the spend tiles
  instead — old Go history alone won't bring the caps back.
- **"Couldn't read OpenCode's local database"** — the database (or data directory) exists but couldn't be
  read this refresh. Quit OpenCode and refresh; if it persists, check the permissions on
  `~/.local/share/opencode`.
- **"Couldn't read OpenCode's auth.json"** — the file exists but is unreadable or not valid JSON. Check
  its permissions, or log into a provider in OpenCode again to rewrite it.
- **An invalid-cost warning appears** — one or more completed records have malformed cost data. Affected
  usage is excluded rather than appearing artificially low. Go meters are hidden only when the malformed
  record falls inside a currently active Go cap window.
- **A dollar value has an estimate marker** — it is an API-rate value derived by OpenCode or OpenUsage,
  not an amount read from your provider bill.
- **Numbers look lower than your dashboard** — the meters are local-observed spend (this Mac only); see the
  note above.

## Under the hood

OpenUsage reads the assistant-message provider, model, `cost`, and token-bucket fields from every `opencode*.db` in the data
directory (OpenCode partitions its database by release channel — stable is `opencode.db`, the preview line
is `opencode-next.db` — so all channels are unioned and duplicate message IDs count once). The Go caps sum
only `opencode-go` messages; the spend tiles and trend sum every provider ID. Database access is read-only,
and no log or credential data is uploaded. When an external row needs a local cost estimate, OpenUsage may
download the same public pricing catalogs used by its other providers. If OpenCode's proposed
`/zen/go/v1/usage` API ships, the same Go key becomes the bearer token for authoritative windows.
