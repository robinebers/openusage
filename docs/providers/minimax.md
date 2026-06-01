# MiniMax

> Uses MiniMax Token Plan remains API with a user-provided API key.

## Overview

- **Protocol:** HTTPS (JSON)
- **Endpoint:** `GET https://api.minimax.io/v1/token_plan/remains` — the officially documented Token Plan usage endpoint ([FAQ](https://platform.minimax.io/docs/token-plan/faq)). The older `coding_plan/remains` path returns an identical payload and is kept only as a legacy fallback.
- **Auth:** `Authorization: Bearer <api_key>`
- **Window model:** the Token Plan now enforces **two** windows simultaneously — a rolling 5-hour `interval` window and a `weekly` window. Each `model_remains[]` bucket reports both.
- **Quota model:** Token Plan tiers (`Plus` / `Max` / `Ultra`) are **credit/token based** — model usage draws from a single shared credit pool (`1000 credits = $1`). The remains API deliberately exposes only a usage-bar percentage: `current_interval_total_count` is `0` and there is **no plan/tier field**; it returns `current_interval_remaining_percent` / `current_weekly_remaining_percent` directly. See [Tier detection](#tier-detection).
- **Display note:** OpenUsage renders every line as a percentage (`0`-`100`), computed as `used = 100 − remaining_percent`, so it visually aligns with other providers (claude/codex).
- **CN note:** current CN endpoint is `https://api.minimaxi.com/v1/token_plan/remains`.

## Authentication

The plugin supports automatic region detection and reads API keys based on the selected region:

**Region auto-selection:**
- If `MINIMAX_CN_API_KEY` is set: tries `CN` first, then `GLOBAL`
- If `MINIMAX_CN_API_KEY` is not set: tries `GLOBAL` first, then `CN`

**Key lookup by region:**
- **CN region**: `MINIMAX_CN_API_KEY` → `MINIMAX_API_KEY` → `MINIMAX_API_TOKEN`
- **GLOBAL region**: `MINIMAX_API_KEY` → `MINIMAX_API_TOKEN`

**Optional tier pin:** set `MINIMAX_PLAN` (or `MINIMAX_CODING_PLAN`) to `Plus` / `Max` / `Ultra` to display your tier — the credit-based remains API does not report it.

If no key is found after attempting both regions, it throws:

- `MiniMax API key missing. Set MINIMAX_API_KEY or MINIMAX_CN_API_KEY.`

## Data Source

Request:

```http
GET /v1/token_plan/remains HTTP/1.1
Host: api.minimax.io
Authorization: Bearer <api_key>
Content-Type: application/json
Accept: application/json
```

`GLOBAL` endpoints, tried in order:

- `https://api.minimax.io/v1/token_plan/remains` (primary, documented)
- `https://www.minimax.io/v1/token_plan/remains`
- `https://api.minimax.io/v1/api/openplatform/coding_plan/remains` (legacy)

`CN` endpoints, tried in order:

- `https://api.minimaxi.com/v1/token_plan/remains` (primary, documented)
- `https://www.minimaxi.com/v1/token_plan/remains`
- `https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains` (legacy)

Expected payload fields (per `model_remains[]` bucket, keyed by `model_name`, e.g. `general`, `video`):

- `base_resp.status_code` / `base_resp.status_msg`
- `model_remains[].model_name`
- **5-hour interval window:**
  - `current_interval_remaining_percent` (preferred signal)
  - `current_interval_total_count` / `current_interval_usage_count` (now `0` for credit-based plans)
  - `start_time` / `end_time` / `remains_time`
- **weekly window:**
  - `current_weekly_remaining_percent` (preferred signal)
  - `current_weekly_total_count` / `current_weekly_usage_count`
  - `weekly_start_time` / `weekly_end_time` / `weekly_remains_time`
- optional plan fields (`current_subscribe_title`, `plan_name`, `plan`)

Example (CN, abridged):

```jsonc
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_remaining_percent": 100,
      "start_time": 1780347600000, "end_time": 1780365600000,
      "current_weekly_remaining_percent": 100,
      "weekly_start_time": 1780243200000, "weekly_end_time": 1780848000000
    },
    { "model_name": "video", "current_interval_remaining_percent": 100, "current_weekly_remaining_percent": 100 }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

## Usage Mapping

- Each `model_remains[]` bucket produces up to two percentage lines: one for the 5-hour `interval` window and one for the `weekly` window.
- For each window, OpenUsage prefers the API-provided remaining percent and emits `used = 100 − remaining_percent` (`limit` is always `100`).
- If a window has no `*_remaining_percent` but reports a positive `*_total_count`, it falls back to count math, treating `*_usage_count` as the remaining count (`used = round((total − remaining) / total × 100)`).
- A window is skipped when it carries neither a remaining percent nor a positive total.
- `model_name` maps to line labels:
  - `general` → `Session` (interval) and `Weekly` (weekly window) — both shown on the overview, matching claude/codex
  - `video` → `Video` (interval) and `Video (Weekly)`
  - any other bucket → title-cased `model_name` (interval) and `<Name> (Weekly)`
- Reset timestamp uses `end_time` / `weekly_end_time`; falls back to `remains_time` / `weekly_remains_time` when the end timestamp is absent.
- `periodDurationMs` is `end_time − start_time` for the interval window and `weekly_end_time − weekly_start_time` for the weekly window, when both bounds are valid.
- **Plan name** is resolved by priority, then suffixed with ` (CN)` / ` (GLOBAL)`:
  1. Explicit API plan/title field (`current_subscribe_title`, `plan_name`, `plan`), normalized to a concise label (`Starter` / `Plus` / `Max` / `Ultra`, plus legacy `*-High-Speed` variants).
  2. Per-region count→tier table applied to the `general` bucket's `current_interval_total_count` (legacy/count-based responses only).
  3. The `MINIMAX_PLAN` (or `MINIMAX_CODING_PLAN`) environment override, normalized like an explicit field.
  4. Generic `Token Plan` baseline, so the line is never blank.
- **Why the override exists:** credit/token-based Token Plans expose **no** plan field and report `current_interval_total_count` as `0`, so steps 1–2 cannot resolve a tier. Set `MINIMAX_PLAN=Plus` (or `Max` / `Ultra`) to surface your actual tier.
- Tier-inference tables retained for legacy/count-based responses (per region):
  - `GLOBAL`: `1500 => Starter`, `4500 => Plus`, `15000 => Max`, `30000 => Ultra`
  - `CN`: `600 => Starter`, `1500 => Plus`, `4500 => Max`, `30000 => Ultra`
- Official tier reference (token/credit based, `Plus` / `Max` / `Ultra`), checked on 2026-06-01:
  - Global: <https://platform.minimax.io/docs/token-plan/intro>
  - CN: <https://platform.minimaxi.com/docs/token-plan/intro>

## Output

- **Plan**: resolved by the priority chain above (API field → count tier → `MINIMAX_PLAN` override → generic `Token Plan`), with a ` (CN)` / ` (GLOBAL)` suffix; always present.
- **Overview progress lines** — `general` bucket:
  - `Session`: 5-hour interval window (percent, `used` `0`-`100`, `limit` `100`); `resetsAt` from `end_time` or `remains_time`
  - `Weekly`: weekly window (percent); `resetsAt` from `weekly_end_time` or `weekly_remains_time`
- **Detail progress lines** (when present):
  - `Video` / `Video (Weekly)`: `video` interval and weekly windows (percent)

## Tier detection

The subscription tier (`Plus` / `Max` / `Ultra`) **cannot be derived from the API**, by design:

- The only usage endpoint is `token_plan/remains` (every subscription/plan/quota endpoint variant returns `404`). Its `coding_plan/remains` alias is byte-for-byte identical.
- Per the [Token Plan FAQ](https://platform.minimax.io/docs/token-plan/faq), the upgraded plan is **credit-based** with a single shared credit pool; "the console usage bar is the source of truth for your current available usage." The API surfaces only that bar — `current_interval_remaining_percent` — and reports `current_interval_total_count` as `0`.
- Tiers differ by credit allowance and windows (see the [migration guide](https://platform.minimax.io/docs/token-plan/migration), e.g. Ultra ≈ 10.3B tokens/month), but the remains response returns **no absolute credit/quota value and no tier name**. A percentage alone (0–100) is identical in shape across all tiers, so it cannot distinguish them.
- The only tier-adjacent field, `interval_boost_permille` (observed `2000`), is unconfirmed across tiers and likely a temporary boost multiplier, not a tier identifier.

Therefore the tier must be supplied manually via `MINIMAX_PLAN` (see [Authentication](#authentication)). If MiniMax later adds a plan field to the response, the priority chain in [Usage Mapping](#usage-mapping) consumes it automatically.

## Errors

| Condition | Message |
|---|---|
| Missing API key | `MiniMax API key missing. Set MINIMAX_API_KEY or MINIMAX_CN_API_KEY.` |
| HTTP 401/403 | `Session expired. Check your MiniMax API key.` |
| API status `base_resp.status_code != 0` | `MiniMax API error: ...` (or session-expired for auth-like errors) |
| Non-2xx | `Request failed (HTTP {status}). Try again later.` |
| Network failure | `Request failed. Check your connection.` |
| Unparseable payload | `Could not parse usage data.` |
