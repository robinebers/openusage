# Devin

Tracks your Devin quota using the login from the Devin CLI or the Devin app.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | Weekly quota used (falls back to the daily figure when Devin reports neither a weekly percentage nor a weekly reset) |
| Daily | Daily quota used (hidden when Devin hides the daily quota) |
| Extra Balance | Overage/extra-usage balance in dollars |

If Devin supplies a weekly reset but omits the weekly percentage, the weekly quota is exhausted (100% used).

When Devin reports your plan name, OpenUsage shows it beside the provider name.

## Where credentials come from

Checked in this order — whichever works first wins:

1. Devin CLI credentials: `~/.local/share/devin/credentials.toml` (uses `windsurf_api_key`, and `api_server_url` when present)
2. The Devin app's local state database

If the CLI credentials fail but the app is signed in with a different account, the app's auth is used instead.

## Troubleshooting

- **"Not logged in"** — run `devin auth login`, or sign into the Devin app, then refresh.
- **Weekly shows the daily figure** — when Devin reports neither a weekly percentage nor a weekly reset, the daily quota is shown in the Weekly row so it stays meaningful.

## Under the hood

Connect RPC `GetUserStatus` on the configured API server (default `server.codeium.com`). Quota percentages arrive as "remaining" and are flipped to "used". No token refresh — a 401/403 switches to the next auth source instead.
