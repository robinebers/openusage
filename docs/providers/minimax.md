# MiniMax

> Uses MiniMax Coding Plan remains API with a user-provided API key.

## Overview

- **Protocol:** HTTPS (JSON)
- **Endpoint:** `GET https://api.minimax.io/v1/api/openplatform/coding_plan/remains`
- **Auth:** `Authorization: Bearer <api_key>`
- **Window model:** dynamic rolling 5-hour limit (per MiniMax Coding Plan docs)

## Authentication

The plugin supports automatic region detection and reads API keys based on the selected region:

**Region auto-selection:**
- If `MINIMAX_CN_API_KEY` is set: tries `CN` first, then `GLOBAL`
- If `MINIMAX_CN_API_KEY` is not set: tries `GLOBAL` first, then `CN`

**Key lookup by region:**
- **CN region**: `MINIMAX_CN_API_KEY` → `MINIMAX_API_KEY` → `MINIMAX_API_TOKEN`
- **GLOBAL region**: `MINIMAX_API_KEY` → `MINIMAX_API_TOKEN`

If no key is found after attempting both regions, it throws:

- `MiniMax API key missing. Set MINIMAX_API_KEY or MINIMAX_CN_API_KEY.`

## Data Source

Request:

```http
GET /v1/api/openplatform/coding_plan/remains HTTP/1.1
Host: api.minimax.io
Authorization: Bearer <api_key>
Content-Type: application/json
Accept: application/json
```

Fallbacks:

- `https://api.minimax.io/v1/coding_plan/remains`
- `https://www.minimax.io/v1/api/openplatform/coding_plan/remains` (legacy fallback; can return Cloudflare HTML)

When the selected region is `CN`, requests use:

- `https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains`
- `https://api.minimaxi.com/v1/coding_plan/remains`

Expected payload fields:

- `base_resp.status_code` / `base_resp.status_msg`
- `model_remains[]`
- `model_remains[].current_interval_total_count`
- `model_remains[].current_interval_usage_count`
- optional remaining aliases (`current_interval_remaining_count`, `current_interval_remains_count`)
- `model_remains[].start_time`
- `model_remains[].end_time`
- `model_remains[].remains_time`
- optional plan fields (`current_subscribe_title`, `plan_name`, `plan`)

## Usage Mapping

- Treat `current_interval_usage_count` as remaining prompts (MiniMax remains API behavior).
- If only remaining aliases are provided, compute `used = total - remaining`.
- If explicit used-count fields are provided, prefer them.
- Plan name is taken from explicit plan/title fields when available.
- If plan fields are missing in GLOBAL mode, infer plan tier from known limits (`100/300/1000/2000` prompts or `1500/4500/15000/30000` model-call equivalents).
- If plan fields are missing in CN mode, infer only exact known CN limits (`600/1500/4500` model-call counts).
- Use `end_time` for reset timestamp when present.
- Fallback to `remains_time` when `end_time` is absent.
- Use `start_time` + `end_time` as `periodDurationMs` when both are valid.

## Output

- **Plan**: best-effort from API payload (normalized to concise label, with ` (CN)` or ` (GLOBAL)` suffix)
- **Session** (overview progress line):
  - `label`: `Session`
  - `format`: count (`prompts`)
  - `used`: computed used prompts
  - `limit`: total prompt limit for current window
  - `resetsAt`: derived from `end_time` or `remains_time`

## Errors

| Condition | Message |
|---|---|
| Missing API key | `MiniMax API key missing. Set MINIMAX_API_KEY or MINIMAX_CN_API_KEY.` |
| HTTP 401/403 | `Session expired. Check your MiniMax API key.` |
| API status `base_resp.status_code != 0` | `MiniMax API error: ...` (or session-expired for auth-like errors) |
| Non-2xx | `Request failed (HTTP {status}). Try again later.` |
| Network failure | `Request failed. Check your connection.` |
| Unparseable payload | `Could not parse usage data.` |
