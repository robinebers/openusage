# Crof.AI

> Uses the Crof.AI API to display usage, credits, plan info, and per-model token breakdown.

## Overview

- **Source of truth:** `https://crof.ai/usage_api/`, `https://crof.ai/pricing_api`, `https://crof.ai/user-api/usage`
- **Auth:** API key (required) + session key (optional, for plan + model breakdown)
- **Provider ID:** `crofai`
- **Usage scope:** requests, credits, plan limits, per-model token usage

## Setup

### Required: API key

Open [crof.ai/usage_api/](https://crof.ai/usage_api/) while logged in. Copy your API key, then add to your shell config (`~/.zshrc`):

```sh
export CROF_AI_API_KEY="your-api-key-here"
```

Then `source ~/.zshrc` and restart OpenUsage.

### Optional: Session key

For progress bar (max requests from pricing) and per-model token breakdown, also set:

```sh
export CROF_AI_SESSION_KEY="your-session-cookie-value"
```

Get it from [crof.ai](https://crof.ai) > DevTools > Application > Cookies > copy the `session` value.

Or save it to `{appDataDir}/plugins_data/crofai/session-key` (env var takes priority).

## Data Sources

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /usage_api/` | `Authorization: Bearer <API_KEY>` | Requests + credits (required) |
| `GET /pricing_api` | `Cookie: session=<SESSION_KEY>` | Plan name + max requests (optional) |
| `GET /user-api/usage` | `Cookie: session=<SESSION_KEY>` | Per-model token breakdown (optional) |

## Display

- **Status badge:** Connected (green) when API responds
- **Usage progress bar:** Used requests / plan max (shown when both API key + session key available)
- **Credits:** Dollar-formatted credit balance
- **Total tokens:** Sum of all models' tokens (shown only with session key)
- **Top models:** Top 5 models sorted by token usage (shown only with session key)

## Failure Behavior

- **Missing API key:** Error asking to set `CROF_AI_API_KEY`
- **401/403 on usage_api:** API key invalid or expired
- **Bad session key:** Only session-backed features drop out, API key data still shows
