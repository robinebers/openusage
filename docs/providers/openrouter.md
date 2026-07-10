# OpenRouter

Tracks your [OpenRouter](https://openrouter.ai) credit balance and spend from your account API key.

## What it tracks

| Metric | Meaning |
|---|---|
| Credits | Lifetime spend against the credits you've purchased (a dollar meter) |
| Balance | Prepaid credits remaining |
| Today | Spend so far today |
| This Week | Spend so far this week |
| This Month | Spend so far this month |
| Key Limit | Spend against this key's cap — shown only when the key has one configured |
| Plan | "Pay as you go" or "Free tier" |

## Where credentials come from

OpenRouter has no companion app or CLI that leaves a credential on your machine, so you supply an API
key. Create one at [openrouter.ai/keys](https://openrouter.ai/keys), then add it in
**Customize → OpenRouter → API Key** (recommended): choose **Add**, paste the key, and select **Save**.
The key is stored at `~/.config/openusage/openrouter.json` and picked up on the next refresh.

You can also provide the key directly (checked in this order, first match wins):

1. **Config file:** `~/.config/openusage/openrouter.json` — the file the in-app editor writes:

   ```json
   { "apiKey": "sk-or-v1-..." }
   ```

   A plain-text file containing just the key, or `~/.config/openrouter/key.json`, also work.

2. **Environment variable:** set `OPENROUTER_API_KEY` in your shell profile (for example `~/.zshrc` or
   `~/.zprofile`). The legacy `OPENROUTER_KEY` name is also accepted as a fallback. On launch the app
   reads your login shell's environment, so a key exported there is picked up even when the app is
   started from Finder or the Dock—not just from a terminal. The API Key section shows an environment
   key as read-only and offers **Override With a Custom Key**.

A key saved through the app overrides an environment key (the config file is checked first); removing
the saved key falls back to the environment key, or to none.

If a config file exists but cannot be read or parsed, OpenUsage checks the remaining config path and
environment variables. A valid fallback still refreshes usage. The API Key editor marks the saved file
as needing attention and does not reveal the fallback as though it were that saved override.

## Troubleshooting

- **"No OpenRouter API key"** — add the key in Customize → OpenRouter → API Key (or the config file / an environment variable), then refresh.
- **"Couldn't read a saved OpenRouter API key"** — check the config file's permissions, or clear it in the API Key editor.
- **"A saved OpenRouter API key is invalid"** — replace or clear the malformed saved file in the API Key editor.
- **"API key invalid"** — the key was rejected (401/403). Check or recreate it at openrouter.ai/keys.

## Under the hood

Two REST calls with a `Bearer` token against `https://openrouter.ai/api/v1`:

- `GET /credits` — account-wide `total_credits` and `total_usage`; the Credits meter and Balance come
  from these.
- `GET /key` — the tier, daily/weekly/monthly spend, and an optional per-key cap.

The calls are independent because OpenRouter can gate either endpoint for a particular key type. Data
from either successful response still renders; one forbidden endpoint does not blank the other. The key
is reported invalid only when both endpoints reject it with 401/403.

A period spend of `$0.00` is shown as a real, measured zero (the API reports it directly) rather than
"No data". Credit values may be up to ~60 seconds stale on OpenRouter's side.
