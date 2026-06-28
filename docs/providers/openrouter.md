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

Unlike the other providers, OpenRouter has no companion app or CLI that leaves a credential on your
machine, so you supply an API key. Create one at [openrouter.ai/keys](https://openrouter.ai/keys),
then add it in **Settings → API Keys** (recommended): expand OpenRouter, paste the key, and Save.
The key is stored at `~/.config/openusage/openrouter.json` and picked up on the next refresh.

You can also provide the key directly (checked in this order, first match wins):

1. **Config file:** `~/.config/openusage/openrouter.json` — the file the Settings card writes:

   ```json
   { "apiKey": "sk-or-v1-..." }
   ```

   A plain-text file containing just the key, or `~/.config/openrouter/key.json`, also work.

2. **Environment variable:** set `OPENROUTER_API_KEY` in your shell profile (e.g. `~/.zshrc` or
   `~/.zprofile`). On launch the app reads your login shell's environment, so a key exported there is
   picked up even when the app is started from Finder or the Dock — not just when run from a terminal.
   When a key is found here, the API Keys card shows it as read-only ("From environment") with a
   checkbox to override it with a saved key.

A key saved through the app overrides an environment key (the config file is checked first); removing
the saved key falls back to the environment key, or to none.

## Troubleshooting

- **"No OpenRouter API key"** — add the key in Settings → API Keys (or the config file / env var), then refresh.
- **"API key invalid"** — the key was rejected (401/403). Check or recreate it at openrouter.ai/keys.

## Under the hood

Two REST calls with a `Bearer` token against `https://openrouter.ai/api/v1`:

- `GET /credits` — account-wide `total_credits` and `total_usage`; the Credits meter and Balance come
  from these. Required for a usable snapshot.
- `GET /key` — best-effort: the tier, daily/weekly/monthly spend, and an optional per-key cap. If this
  call fails, the balance still renders from `/credits`.

A period spend of `$0.00` is shown as a real, measured zero (the API reports it directly) rather than
"No data". Credit values may be up to ~60 seconds stale on OpenRouter's side.
