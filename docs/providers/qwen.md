# Qwen

Tracks [Qwen Cloud](https://home.qwencloud.com) Token Plan (individual edition) usage quotas — the
rolling 5-hour and weekly windows shown on the plan's billing page.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage (percentage) |
| Weekly | 7-day rolling window usage (percentage) |

When Qwen reports your plan tier, OpenUsage shows it beside the provider name (with the tier's
quota numbers when available). If auto-renew is off, an amber notice warns how many days the plan
has left.

## Where credentials come from

Qwen API keys are inference-only — plan usage lives behind the web console, authenticated by your
browser session. OpenUsage captures that session once, in-app:

1. **Sign in from the app** — open Qwen in **Customize**, click **Sign In**, and log in to
   qwencloud.com in the window that opens. OpenUsage verifies the session and stores the needed
   cookies in `~/.config/openusage/qwen.json` (readable only by your user).
2. **Or paste cookies by hand** — copy the `Cookie` header from your browser's DevTools on the
   billing page and save it to `~/.config/openusage/qwen.json`:

```json
{"cookies":"login_qwencloud_ticket=…; cna=…"}
```

The sign-in window keeps its own browser state, so after one sign-in, signing in again later
recaptures the still-live session without retyping anything. Sessions last roughly 30 days; when
yours expires, the card shows an error and Sign In works the same way. Nothing leaves your Mac
except the same calls qwencloud.com's own billing page makes.

## Setup

1. Subscribe to the [Qwen Token Plan](https://home.qwencloud.com/billing/subscription/token-plan-individual).
2. Open **Customize → Qwen**, click **Sign In**, and log in.
3. Qwen appears on the dashboard and (after you star a metric) the menu bar on the next refresh.

## Under the hood

The same internal endpoints qwencloud.com's billing page uses (stable in practice):

- `GET https://home.qwencloud.com/tool/user/info.json` — session check and the `sec_token` every
  other call carries.
- `POST https://cs-data.qwencloud.com/data/api.json` three times — `usage` (the meters),
  `subscription` (plan tier + renewal, best-effort), and `quota-config` (per-tier quota numbers,
  best-effort; a failure here doesn't blank the meters).

Percentages arrive as fractions of 1.0 and reset times as epoch milliseconds. Missing required
usage values are reported as an invalid response instead of being shown as zero. Only the
international (Singapore) plan edition is supported; the region is carried in the config file so
others can be added later.

## Troubleshooting

- **"Not signed in to Qwen Cloud"** — sign in from Customize → Qwen, or save your cookies to the
  config file.
- **"Qwen Cloud session expired"** — normal after ~30 days; sign in again from Customize → Qwen.
- **Sign-in window won't complete** — qwencloud.com occasionally challenges automated browsers;
  log in normally in the window (it's a real browser view), or fall back to pasting cookies.
