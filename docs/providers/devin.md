# Devin

Tracks your Devin quota using the login from the Devin CLI or the Devin app.

## What it tracks

| Metric | Meaning |
|---|---|
| Weekly | Weekly quota used (falls back to the daily figure when Devin reports no weekly quota) |
| Daily | Daily quota used (hidden when Devin hides the daily quota) |
| Extra Balance | Overage/extra-usage balance in dollars |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Checked in this order — whichever works first wins:

1. Devin CLI credentials: `~/.local/share/devin/credentials.toml` (uses `windsurf_api_key`, and `api_server_url` when present)
2. The Devin app's local state database

If the CLI credentials fail but the app is signed in with a different account, the app's auth is used instead.

## Troubleshooting

- **"Not logged in"** — OpenUsage found no usable credential. Run `devin auth login`, or sign into the Devin app, then refresh.
- **"Session expired"** — every available credential was rejected. Sign in again with the Devin CLI or app, then refresh.
- **Connection, request, or response error** — at least one credential encountered a non-authentication failure. Check your connection and Devin's service, then try again; this failure is kept instead of being replaced by a misleading login prompt from another stale credential.
- **Weekly shows the daily figure** — when Devin reports no separate weekly quota, the daily quota is shown in the Weekly row so it stays meaningful.

## Under the hood

Connect RPC `GetUserStatus` on the configured API server (default `server.codeium.com`). Quota percentages arrive as "remaining" and are flipped to "used". There is no token refresh; a failed credential falls through to the next distinct auth source when one exists. If none succeed, a connection, HTTP, or response failure takes precedence over a 401/403 login hint.
