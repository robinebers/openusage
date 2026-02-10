# Perplexity Provider (Issue #122)

Date: 2026-02-08
Status: Implemented (updated for Perplexity macOS v5.1 local snapshot behavior)

## Goal

Add a Perplexity plugin using local macOS app session data only, with no API-key fallback.

## Source of truth (discovery)

- Preferences plist: `~/Library/Containers/ai.perplexity.mac/Data/Library/Preferences/ai.perplexity.mac.plist`
- Cache DB: `~/Library/Containers/ai.perplexity.mac/Data/Library/Caches/ai.perplexity.mac/Cache.db`
- Endpoint: `GET https://www.perplexity.ai/api/user`

## Decisions

1. Auth source priority:
   - Primary: `current_user__data` snapshot extracted from local Perplexity plist.
   - Secondary: `authToken` extracted from local Perplexity plist.
   - Fallback: bearer token extracted from latest cached `/api/user` request blob in Cache DB.
2. v1 auth model:
   - Local session only.
   - No env var or API key mode.
3. Usage mapping:
   - Parse `remaining_pro`, `remaining_research`, `remaining_labs` (+ optional limit fields).
   - Prefer explicit limit fields to compute Pro progress.
   - Use `uploadLimit` only as free-tier Pro fallback.
   - Do not use `queryCount` to infer Pro limits.
   - When limits exist, render count progress bars.
   - When only remaining values exist, render `<n> left` text lines.
4. Empty-usage behavior:
   - If logged in but no quota fields are usable, show:
     `Usage data unavailable. Open Perplexity app and run a search, then try again.`

## Files

- `plugins/perplexity/plugin.js`
- `plugins/perplexity/plugin.json`
- `plugins/perplexity/icon.svg`
- `plugins/perplexity/plugin.test.js`
- `docs/providers/perplexity.md`
- `README.md`
