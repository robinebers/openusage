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

1. `~/.config/openusage/zai.json` — `{"apiKey":"…"}` (the file Settings writes to)
2. `~/.config/zai/key.json`
3. The `ZAI_API_KEY` environment variable
4. The `GLM_API_KEY` environment variable (the legacy Zhipu name, still accepted)

You can also add and rotate the key from **Settings → API Keys** without touching a file. Either
way, nothing leaves your Mac except the same API calls Z.ai's own subscription UI makes.

## Setup

1. [Subscribe to a GLM Coding plan](https://z.ai/subscribe) and get your API key from the
   [Z.ai console](https://z.ai/manage-apikey/apikey-list).
2. Add the key to OpenUsage via **Settings → API Keys**, **or** export it:

```bash
export ZAI_API_KEY="YOUR_API_KEY"
```

3. Z.ai appears on the dashboard and (after you star a metric) the menu bar on the next refresh.

## Under the hood

Two undocumented internal endpoints Z.ai's own subscription UI uses (stable in practice):

- `GET https://api.z.ai/api/biz/subscription/list` — plan name (best-effort; a failure here doesn't
  blank the meters).
- `GET https://api.z.ai/api/monitor/usage/quota/limit` — the quota meters.

The quota response carries a `limits` array. Each `TOKENS_LIMIT` entry is a token window; its
window length decides which meter it feeds (sub-daily → Session, multi-day → Weekly), so a `TIME_LIMIT` entry is the monthly web-search count. Reset times come back as epoch milliseconds.

## Troubleshooting

- **"No Z.ai API key"** — add a key in Settings → API Keys, or export `ZAI_API_KEY`.
- **"Z.ai API key invalid"** — the key was rejected (401/403). Regenerate it in the
  [Z.ai console](https://z.ai/manage-apikey/apikey-list).
- **"No active GLM Coding Plan"** (amber notice by the name) — the key is valid, but the account has no
  GLM Coding Plan, so there's nothing to meter. Subscribe at [z.ai/subscribe](https://z.ai/subscribe);
  usage appears once your plan is active.
- **Meters show "No usage data"** — you have a plan, but the quota endpoint returned no usable limits
  yet. Check your [plan](https://z.ai/manage-apikey/coding-plan/personal/my-plan).
