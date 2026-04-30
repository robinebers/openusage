# Fireworks AI

> Based on Fireworks AI's documented control-plane API and quota model.

## Overview

- **Product:** [Fireworks AI](https://fireworks.ai/)
- **Auth:** Fireworks API key
- **Primary API:** `https://api.fireworks.ai/v1`
- **Key setup:** macOS Keychain first, `FIREWORKS_API_KEY` fallback

OpenUsage uses Fireworks' official account + quota endpoints plus Fireworks' official billing-export path when available. It does not depend on a browser login.

## Plugin Metrics

| Metric | Source | Scope | Format | Notes |
| --- | --- | --- | --- | --- |
| Serverless usage | billing export or aggregate token counter | overview | text | Main cumulative usage line, shown as a compact token total like `104.85M tokens` |
| Prompt tokens | billing export or token counter | overview | text | Prompt/input token total for the selected rolling window |
| Generated tokens | billing export or token counter | overview | text | Generated/output token total for the selected rolling window |
| Month spend | `monthly-spend-usd.usage` | overview | text | Current calendar-month billable spend |
| Budget | `monthly-spend-usd.value` / `maxValue` | detail | text | Configured monthly budget plus the tier cap |
| Status | account `state` / `suspendState` | detail | badge | Only shown when the account is not in a healthy state |

The plan label is inferred from Fireworks' documented monthly budget cap tiers:

- Tier 1: `$50`
- Tier 2: `$500`
- Tier 3: `$5,000`
- Tier 4: `$50,000`

## API Calls

### 1) List accounts

```http
GET https://api.fireworks.ai/v1/accounts?pageSize=200
Authorization: Bearer <API_KEY>
Accept: application/json
```

This returns the accounts attached to the key. OpenUsage picks the first healthy account (`READY` + `UNSUSPENDED`) and falls back to the first returned account if none are healthy.

### 2) List quotas

```http
GET https://api.fireworks.ai/v1/accounts/{account_id}/quotas?pageSize=200
Authorization: Bearer <API_KEY>
Accept: application/json
```

OpenUsage currently reads:

- `monthly-spend-usd`
- aggregate token counters when the quota payload exposes them
- any other live quota only when it is a truthful user-facing limit worth showing

### 3) Export billing metrics

Fireworks documents `firectl billing export-metrics` as the official way to export billable usage, and the command accepts `--api-key` and `--account-id`. OpenUsage uses that path when available to compute rolling token totals without relying on a browser session. The working export format is date-only `YYYY-MM-DD` windows.

Observed/expected quota fields:

- `name`
- `value`
- `maxValue`
- `usage`
- `currentUsage`
- `updateTime`

## Credential Setup

### Recommended: macOS Keychain

OpenUsage looks for this service name first:

```text
OpenUsage Fireworks AI API Key
```

Add/update it with:

```bash
security add-generic-password -U -a "$(id -un)" -s "OpenUsage Fireworks AI API Key" -w "<your-fireworks-api-key>"
```

### Fallback: environment variable

```bash
export FIREWORKS_API_KEY="<your-fireworks-api-key>"
```

Restart OpenUsage after changing shell env. The host caches env values for the app session.

## Notes

- Fireworks' official docs document aggregate usage export through `firectl billing export-metrics`, but not a public documented browser-free history endpoint for the dashboard chart itself. OpenUsage therefore prefers the official billing-export path for cumulative token totals, falls back to live account token counters when present, and otherwise falls back to spend/budget only.
- Live validation on this account showed that Fireworks exposes monthly spend and request-rate quotas, but not prompt/generated token-per-second quotas. OpenUsage therefore does not ship speculative prompt/generated rate bars for Fireworks.
- Fireworks docs describe monthly spend limits and tier caps. OpenUsage labels the live spend number as `Month spend` to avoid implying a settled invoice total or a rolling 30-day window.
- If no key is configured, OpenUsage shows a direct setup hint instead of a generic failure.
