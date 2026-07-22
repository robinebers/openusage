# Command Code

Tracks [Command Code](https://commandcode.ai/) plan limits, balance, and request activity.

## What it tracks

| Metric | Meaning |
|---|---|
| 5-Hour | Usage in the current rolling five-hour window |
| Weekly | Usage in the current rolling seven-day window |
| Monthly | Usage against the current billing-cycle credits |
| Balance | Remaining plan, purchased, and free credits |
| Requests | Requests made during the current billing cycle |

Rows only appear when they apply to the account. Accounts without rolling caps or a usable subscription
still show their available Balance and Requests data.

Limit rows keep dollars in the dashboard but use percentages in the menu bar. Pace projection tooltips begin with `Projected` and follow the active Used/Left mode; spent meters read `Limit reached`.

OpenUsage also shows the plan reported by Command Code. This includes **Go**, the $1/month entry plan;
its credits and limits come from the account response rather than being hardcoded in the app.

## Where credentials come from

OpenUsage reads the first usable credential in this order:

1. The `COMMAND_CODE_API_KEY` environment variable.
2. The Command Code CLI login in `~/.commandcode/auth.json`.

If `cmd` is already logged in, no additional setup is needed. OpenUsage only reads the API key needed
for usage requests; it does not display or log the key.

## Under the hood

OpenUsage makes read-only `GET` requests to Command Code's official API at
`https://api.commandcode.ai`:

- `/alpha/whoami` — resolves whether usage belongs to a personal account or an organization.
- `/alpha/billing/credits` — balance plus the rolling 5-Hour and Weekly limits.
- `/alpha/billing/subscriptions` — plan name and current billing period.
- `/alpha/usage/summary` — billing-cycle usage and request count.

The API key is sent only to `api.commandcode.ai` as a Bearer credential. OpenUsage does not send the
credential, usage response, or account details anywhere else.

## Troubleshooting

- **"Not logged in"** — run `cmd login`, or set `COMMAND_CODE_API_KEY`.
- **"Session expired"** — run `cmd login` again, or replace the exported API key.
- **"Could not reach Command Code"** — check the network connection and try refreshing again.
- **"Command Code response was invalid"** — the API returned data OpenUsage could not recognize; try
  again later.
