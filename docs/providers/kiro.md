# Kiro

Tracks Kiro CLI credit usage using the login from the Kiro CLI.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Monthly credits used out of your plan's total (e.g. 6 of 50), with the billing cycle reset countdown |
| Overage Charges | Total overage spend in USD, shown only when non-zero |
| Plan | Your subscription tier (e.g. "Kiro Free", "Kiro Pro") |

## Where credentials come from

Sign in once with the Kiro CLI (`kiro-cli login`); OpenUsage reads the same credentials from `~/Library/Application Support/kiro-cli/data.sqlite3`. No extra login or API key is needed.

## Troubleshooting

- **"Not logged in"** — run `kiro-cli login` and then refresh.
- **"Session expired"** — run `kiro-cli login` again; the token needs to be refreshed.
- **Credits show "No data"** — make sure your account has an active Kiro subscription and that `kiro-cli` is installed and logged in.

## Under the hood

`POST https://codewhisperer.us-east-1.amazonaws.com/` with target `AmazonCodeWhispererService.GetUsageLimits` — the same call the Kiro CLI makes to display your usage. The access token from the local SQLite database is sent as a Bearer token. A 401 or 403 response surfaces as a "session expired" error.
