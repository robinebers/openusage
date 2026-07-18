# Kimi Code

Tracks [Kimi Code](https://www.kimi.com/code) (Moonshot AI) subscription quotas.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window usage (percentage) |
| Weekly | Weekly allowance usage (percentage) |

When Kimi reports your membership level, OpenUsage shows it beside the provider name (e.g.
"Intermediate").

## Where credentials come from

OpenUsage reads the first credential it finds, in this order:

1. `~/.config/openusage/kimi.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. The `KIMI_API_KEY` environment variable
3. The Kimi Code CLI's existing login: `~/.kimi-code/credentials/kimi-code.json` (or the older
   `~/.kimi/credentials/kimi-code.json`)

If you use the Kimi Code CLI, no setup is needed — OpenUsage reuses the login you already have.
Kimi access tokens are short-lived (~15 minutes), so OpenUsage refreshes them the same way the CLI
does and writes the rotated tokens back to the CLI's credential file, keeping both signed in.

An API key is the right choice when you don't run the CLI — say, a Kimi Code subscription driven
through Claude Code. Create one in the [Kimi Code console](https://www.kimi.com/code/console) and
add it via **Settings → API Keys**, or export it:

```bash
export KIMI_API_KEY="YOUR_API_KEY"
```

A saved or exported API key takes precedence over the CLI login (and never touches the CLI's
credential file). Either way, nothing leaves your Mac except the same API calls Kimi's own usage
view makes.

## Under the hood

- `GET https://api.kimi.com/coding/v1/usages` — the quota meters and membership level, with the
  CLI access token or API key as the Bearer credential.
- `POST https://auth.kimi.com/api/oauth/token` — the CLI token refresh (`grant_type=refresh_token`
  with the CLI's public client id). Only used on the CLI-login path.

The usage response carries a windowed `limits` array and a top-level `usage` quota. The shortest
declared window (300 minutes in current payloads) is the Session meter; the top-level quota is the
Weekly meter. Quota numbers arrive as strings and are parsed accordingly; missing required values
are reported as an invalid response instead of being shown as zero.

## Troubleshooting

- **"Not logged in"** — sign in with the Kimi Code CLI, or add an API key in Settings → API Keys.
- **"Session expired"** — the CLI's refresh token was rejected. Sign in with the Kimi Code CLI
  again, then refresh.
- **"Kimi API key invalid"** — the key was rejected (401/403). Create a new one in the
  [Kimi Code console](https://www.kimi.com/code/console).
- **Meters show "No usage data"** — the account answered without any recognizable quota (e.g. no
  active Kimi Code plan). Check your plan in the [console](https://www.kimi.com/code/console).
