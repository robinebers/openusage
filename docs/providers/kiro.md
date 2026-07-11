# Kiro

Tracks your Kiro credit usage using the login from the Kiro IDE or kiro-cli.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Monthly plan credits used vs. total (e.g. 50 on Free, 1,000 on Pro) |
| Bonus Credits | Free-trial or bonus credit pool when present |
| Overages | Whether overage (pay-as-you-go) spending is enabled or disabled |

When Kiro reports your plan name, OpenUsage shows it beside the provider name.

## Where credentials come from

Checked in this order — whichever works first wins:

1. Kiro IDE token file: `~/.aws/sso/cache/kiro-auth-token.json` (social login — Google, GitHub, Microsoft)
2. kiro-cli SQLite database: `~/Library/Application Support/kiro-cli/data.sqlite3` (OIDC login)

The profile ARN required by the usage API comes from the token file, or from `~/Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/profile.json` when not embedded in the token.

## Troubleshooting

- **"Sign in to Kiro IDE or run kiro-cli login"** — open Kiro IDE and sign in, or run `kiro-cli login`, then refresh.
- **"Kiro profile not found"** — the token was found but no profile ARN. Open Kiro IDE, select your profile, then refresh.
- **"Kiro session expired"** — the access token expired and refresh failed. Sign in again to Kiro IDE or run `kiro-cli login`.

## Under the hood

Calls `GET https://q.<region>.amazonaws.com/getUsageLimits` on the AWS CodeWhisperer / Q runtime with the Kiro bearer token and profile ARN. When the access token is expired (401/403), it refreshes via Kiro's desktop auth endpoint (social login) or AWS SSO OIDC (kiro-cli login) and retries once.
