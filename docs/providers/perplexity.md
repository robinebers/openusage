# Perplexity

> Uses Perplexity macOS app session data from local cache (no manual configuration).

## Overview

- **Protocol:** HTTPS (JSON)
- **Auth:** Bearer token extracted from local Perplexity app cache request object
- **Data sources:**
  - `Cache.db` (local CFNetwork cache) for token + app headers
  - REST API for balance + usage analytics

## Local Session (Required)

1. Install the Perplexity macOS app.
2. Open the app and sign in once.

The plugin checks for the Perplexity cache DB at:

- `~/Library/Containers/ai.perplexity.mac/Data/Library/Caches/ai.perplexity.mac/Cache.db`
- fallback: `~/Library/Caches/ai.perplexity.mac/Cache.db`

It reads the cached request object for:

- `https://www.perplexity.ai/api/user`

Then extracts the cached request's `Authorization: Bearer ...` token (and app-like headers).

If no local session is found, the plugin throws:

- `Not logged in. Sign in via Perplexity app.`

## Balance + Usage (No Env Vars)

When a bearer token is present in the cache DB, the plugin calls:

- `GET https://www.perplexity.ai/rest/pplx-api/v2/groups` (resolve `<api_org_id>`)
- `GET https://www.perplexity.ai/rest/pplx-api/v2/groups/<api_org_id>` (read `customerInfo.balance`)
- `GET https://www.perplexity.ai/rest/pplx-api/v2/groups/<api_org_id>/usage-analytics` (sum `cost`)

## Output

- **Plan**: `Pro` when `customerInfo.is_pro === true`
- **Usage** (single progress bar line):
  - `limit = customerInfo.balance`
  - `used = sum(usage-analytics[].meter_event_summaries[].cost)`
  - `resetsAt` not set (UI shows `$<limit> limit`, no reset countdown)

## Limitations

- Cache format is app-version dependent and may change.
- The REST endpoints used are not a public usage API (may change or break without notice).
- Some REST endpoints may be protected by Cloudflare; the plugin sends app-like headers from the cached request object, but may still be blocked (usage will be unavailable).
