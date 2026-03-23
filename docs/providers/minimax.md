# MiniMax

> Uses MiniMax Coding Plan remains API with a user-provided API key.

## Overview

- **Protocol:** HTTPS (JSON)
- **Endpoint:** `GET https://api.minimax.io/v1/api/openplatform/coding_plan/remains`
- **Auth:** `Authorization: Bearer <api_key>`
- **Window model:** dynamic rolling 5-hour limit (per MiniMax Coding Plan docs)
- **Display note:** OpenUsage shows the raw text-session counts from the remains API as `model-calls`, because that matches the observed official usage display.
- **CN note:** current CN docs use `https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`.

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

- `https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`
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

- Treat `current_interval_usage_count` as the remaining raw session/resource count returned by the remains API.
- For the main text `Session` line, OpenUsage displays the raw remains numbers as `model-calls` rather than converting them to `prompts`.
- If only remaining aliases are provided, compute `used = total - remaining`.
- If explicit used-count fields are provided, prefer them.
- Plan name is taken from explicit plan/title fields when available, and normalized to a shared six-plan naming scheme:
  - `Starter`
  - `Plus`
  - `Max`
  - `Plus-High-Speed`
  - `Max-High-Speed`
  - `Ultra-High-Speed`
- If plan fields are missing, infer the plan tier from the current Token Plan quota table for the selected region:
  - `GLOBAL` raw `model-calls`: `1500 => Starter`, `4500 => Plus`, `15000 => Max`, `30000 => Ultra-High-Speed`
  - `CN` raw `model-calls`: `600 => Starter`, `1500 => Plus`, `4500 => Max`, `30000 => Ultra-High-Speed`
- For overlapping middle tiers, the plugin also inspects companion daily quotas when present to disambiguate `Standard` vs `High-Speed`:
  - `GLOBAL 4500`: `image-01 50` or `Speech 2.8 4000` => `Plus`; `image-01 100` or `Speech 2.8 9000` => `Plus-High-Speed`
  - `GLOBAL 15000`: `image-01 120` or `Speech 2.8 11000` => `Max`; `image-01 200` or `Speech 2.8 19000` => `Max-High-Speed`
  - `CN 1500`: `image-01 50` or `speech-hd 4000` => `Plus`; `image-01 100` or `speech-hd 9000` => `Plus-High-Speed`
  - `CN 4500`: `image-01 120` or `speech-hd 11000` => `Max`; `image-01 200` or `speech-hd 19000` => `Max-High-Speed`
- If those companion quotas are absent or conflicting, the plugin falls back to the coarse family label (`Plus` / `Max`) instead of guessing.
- Additional `model_remains[]` companion resource buckets are rendered as separate daily detail lines in both `GLOBAL` and `CN` mode, for example `speech-hd` (`Text to Speech HD`) or `image-01`.
- Use `end_time` for reset timestamp when present.
- Fallback to `remains_time` when `end_time` is absent.
- Use `start_time` + `end_time` as `periodDurationMs` when both are valid.
- Non-session companion resource lines use a daily window when only `remains_time` is present.
- Prompt-based marketing copy is ignored by the plugin; all inference is based on raw remains quotas and companion resource buckets.
- Official package tables used for this split, checked on 2026-03-23:
  - Global: <https://platform.minimax.io/docs/token-plan/intro>
  - CN: <https://platform.minimaxi.com/docs/token-plan/intro>

## Output

- **Plan**: best-effort from API payload (normalized to concise label, with ` (CN)` or ` (GLOBAL)` suffix)
- **Session** (overview progress line):
  - `label`: `Session`
  - `format`: count (`model-calls`)
  - `used`: computed used model-call count from raw remains data
  - `limit`: raw session limit from the remains payload
  - `resetsAt`: derived from `end_time` or `remains_time`
- **Extra resources** (detail progress lines when present in either region):
  - `Text to Speech HD` / `Text to Speech Turbo`: count (`chars`)
  - `Image Generation` / `image-01`: count (`images`)

## Errors

| Condition | Message |
|---|---|
| Missing API key | `MiniMax API key missing. Set MINIMAX_API_KEY or MINIMAX_CN_API_KEY.` |
| HTTP 401/403 | `Session expired. Check your MiniMax API key.` |
| API status `base_resp.status_code != 0` | `MiniMax API error: ...` (or session-expired for auth-like errors) |
| Non-2xx | `Request failed (HTTP {status}). Try again later.` |
| Network failure | `Request failed. Check your connection.` |
| Unparseable payload | `Could not parse usage data.` |
