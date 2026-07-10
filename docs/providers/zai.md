# Z.ai

Tracks [Z.ai](https://z.ai) (Zhipu AI) GLM Coding Plan usage quotas for coding subscriptions.

## What it tracks

| Metric | Meaning |
|---|---|
| Session | 5-hour rolling window token usage (percentage) |
| Weekly | 7-day rolling window token usage (percentage) |
| Web Searches | Monthly web-search / web-reader / Zread calls (used / limit) |
| Plan | Your plan name (optional widget) |

## Where credentials come from

Z.ai has no companion CLI/app that OpenUsage can reuse a credential from, so you supply an API key.
OpenUsage reads it from the first place it finds one, in this order:

1. `~/.config/openusage/zai.json` — `{"apiKey":"…"}` (the file the in-app editor writes)
2. `~/.config/zai/key.json`
3. The `ZAI_API_KEY` environment variable
4. The `GLM_API_KEY` environment variable (the legacy Zhipu name, still accepted)

You can also manage the key from **Customize → Z.ai → API Key** without touching a file. The
key is used only for Z.ai's subscription endpoints. OpenUsage's separate anonymous summaries and public
pricing downloads are covered in [Privacy & usage data](../privacy.md).

If a config file exists but cannot be read or parsed, OpenUsage checks the remaining config path and
environment variables. A valid fallback still refreshes usage. The API Key editor marks the saved file
as needing attention and does not reveal the fallback as though it were that saved override.

## Setup

1. [Subscribe to a GLM Coding plan](https://z.ai/subscribe) and get your API key from the
   [Z.ai console](https://z.ai/manage-apikey/apikey-list).
2. Add the key to OpenUsage via **Customize → Z.ai → API Key**, **or** export it:

```bash
export ZAI_API_KEY="YOUR_API_KEY"
```

3. If Z.ai is turned on, saving the key refreshes it immediately. Otherwise, turn it on in the
   Customize provider list; after data loads it appears on the dashboard and, once starred, the menu bar.

## Under the hood

Two undocumented internal endpoints Z.ai's own subscription UI uses (stable in practice):

- `GET https://api.z.ai/api/biz/subscription/list` — plan name (best-effort; a failure here doesn't
  blank the meters).
- `GET https://api.z.ai/api/monitor/usage/quota/limit` — the quota meters.

The quota response carries a `limits` array. Each `TOKENS_LIMIT` entry is a token window; its
window length decides which meter it feeds (sub-daily → Session, multi-day → Weekly), so a `TIME_LIMIT` entry is the monthly web-search count. Reset times come back as epoch milliseconds.

## Troubleshooting

- **"No Z.ai API key"** — add a key in Customize → Z.ai → API Key, or export `ZAI_API_KEY`.
- **"Couldn't read a saved Z.ai API key"** — check the config file's permissions, or clear it in the API Key editor.
- **"A saved Z.ai API key is invalid"** — replace or clear the malformed saved file in the API Key editor.
- **"Z.ai API key invalid"** — the key was rejected (401/403). Regenerate it in the
  [Z.ai console](https://z.ai/manage-apikey/apikey-list).
- **"No active GLM Coding Plan"** (amber notice by the name) — the key is valid, but the account has no
  GLM Coding Plan, so there's nothing to meter. Subscribe at [z.ai/subscribe](https://z.ai/subscribe);
  usage appears once your plan is active.
- **Meters show "No usage data"** — you have a plan, but the quota endpoint returned no usable limits
  yet. Check your [plan](https://z.ai/manage-apikey/coding-plan/personal/my-plan).
