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
machine, so you supply an API key. Create one at [openrouter.ai/keys](https://openrouter.ai/keys), then
provide it one of two ways (checked in this order, first match wins):

1. **Config file (recommended):** create `~/.config/openusage/openrouter.json`:

   ```json
   { "apiKey": "sk-or-v1-..." }
   ```

   A plain-text file containing just the key, or `~/.config/openrouter/key.json`, also work.

2. **Environment variable:** set `OPENROUTER_API_KEY`. Because the macOS app does not inherit your
   shell environment, this only reaches the app when it's launched from a shell or seeded with
   `launchctl setenv OPENROUTER_API_KEY sk-or-v1-...`. The config file is the reliable path.

## Troubleshooting

- **"No OpenRouter API key"** — add the key via the config file above (or the environment variable), then refresh.
- **"API key invalid"** — the key was rejected (401/403). Check or recreate it at openrouter.ai/keys.

## Under the hood

Two REST calls with a `Bearer` token against `https://openrouter.ai/api/v1`:

- `GET /credits` — account-wide `total_credits` and `total_usage`; the Credits meter and Balance come
  from these. Required for a usable snapshot.
- `GET /key` — best-effort: the tier, daily/weekly/monthly spend, and an optional per-key cap. If this
  call fails, the balance still renders from `/credits`.

A period spend of `$0.00` is shown as a real, measured zero (the API reports it directly) rather than
"No data". Credit values may be up to ~60 seconds stale on OpenRouter's side.
