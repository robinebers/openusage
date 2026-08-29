# OrcaRouter

Tracks your [OrcaRouter](https://www.orcarouter.ai) spend and wallet balance from your account API key.

## What it tracks

| Metric | Meaning |
|---|---|
| Total Usage | Workspace-wide spend so far, in USD |
| Balance | The funded wallet balance remaining (can be negative if usage passed the funded amount) |
| Free Credit | Sum of per-model free credits, in USD |

## Where credentials come from

Like OpenRouter, OrcaRouter has no companion app or CLI that leaves a credential on your
machine, so you supply an API key. Create one at [orcarouter.ai](https://www.orcarouter.ai), then add it
in **Settings → API Keys** (recommended): expand OrcaRouter, paste the key, and Save.
The key is stored at `~/.config/openusage/orcarouter.json` and picked up on the next refresh.

You can also provide the key directly (checked in this order, first match wins):

1. **Config file:** `~/.config/openusage/orcarouter.json` — the file the Settings card writes:

   ```json
   { "apiKey": "sk-orca-..." }
   ```

   A plain-text file containing just the key, or `~/.config/orcarouter/key.json`, also work.

2. **Environment variable:** set `ORCAROUTER_API_KEY` in your shell profile (e.g. `~/.zshrc` or
   `~/.zprofile`). On launch the app reads your login shell's environment, so a key exported there is
   picked up even when the app is started from Finder or the Dock — not just when run from a terminal.
   When a key is found here, the API Keys card shows it as read-only ("From environment") with a
   checkbox to override it with a saved key.

A key saved through the app overrides an environment key (the config file is checked first); removing
the saved key falls back to the environment key, or to none.

## Troubleshooting

- **"No OrcaRouter API key"** — add the key in Settings → API Keys (or the config file / env var), then refresh.
- **"API key invalid"** — the key was rejected (401/403). Check or recreate it at orcarouter.ai.

## Under the hood

Two REST calls with a `Bearer` token against `https://api.orcarouter.ai/v1`:

- `GET /dashboard/billing/usage` — workspace-wide `total_usage` in USD. Required for a usable snapshot.
- `GET /balance` — the funded wallet (`paid_balance`) and per-model free credits. If this call fails, the
  Total Usage row still renders.

A spend of `$0.00` is shown as a real, measured zero (the API reports it directly) rather than "No data".
Usage is aggregated at the workspace level — OrcaRouter's dashboard does not currently break spend down
per API key.
