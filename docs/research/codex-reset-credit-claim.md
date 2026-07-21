# Codex Rate-Limit Reset Credits: How Claiming Works

Research + live verification of the Codex "reset credit" claim flow, done 2026-07-12.
OpenUsage lists these credits and can claim one from the Codex provider; this is the
protocol reference behind that implementation.

> **Historical quota note:** the live verification below predates Codex's removal of its
> core five-hour limit. OpenUsage now exposes only the core Weekly meter. References to two
> core windows and `windows_reset: 2` record the API behavior observed on 2026-07-12; the
> model-specific Spark limit can still carry its own five-hour and weekly windows.

Sources: the open-source Codex CLI (`openai/codex`, `codex-rs/backend-client/src/client/rate_limit_resets.rs`,
`codex-rs/tui/src/chatwidget/reset_credits.rs`, `codex-rs/tui/src/chatwidget/usage.rs`,
`codex-rs/app-server/src/request_processors/account_processor/rate_limit_resets.rs`), plus a
live end-to-end claim against a real account (one credit, hours before it expired).

## What a reset credit is

OpenAI grants Codex users occasional free "rate limit resets". Redeeming one immediately
resets the account's Codex rate-limit windows — on paid plans the 5-hour **and** weekly
windows together (`windows_reset: 2`); on Free/Go plans the monthly window. Credits expire
(typically 30 days after being granted) and are gone once redeemed or expired.

## Endpoints

Both live under the ChatGPT backend base URL (`https://chatgpt.com/backend-api`). The CLI
also has a `PathStyle::CodexApi` variant (`/api/codex/...` instead of `/wham/...`) for
enterprise/alternative base URLs; OpenUsage uses the ChatGPT style.

Headers on every call (identical to what OpenUsage's Codex usage client already sends):

- `Authorization: Bearer <access_token>` (the ChatGPT OAuth access token from `~/.codex/auth.json`)
- `ChatGPT-Account-Id: <account_id>` (from the same file)
- `Content-Type: application/json` on the POST

### List (already implemented in OpenUsage)

`GET /wham/rate-limit-reset-credits`

```json
{
  "credits": [
    {
      "id": "RateLimitResetCredit_…",
      "reset_type": "codex_rate_limits",
      "status": "available",            // available | redeeming | redeemed
      "granted_at": "2026-06-12T03:57:42.677034Z",
      "expires_at": "2026-07-12T03:57:42.677034Z",   // may be null (never expires)
      "redeem_started_at": null,
      "redeemed_at": null,
      "profile_image_url": "https://…/codex-icon-200.png",
      "profile_user_id": "Codex Team",
      "title": "Full reset (Weekly + 5 hr)",
      "description": "Thanks for using Codex! You've been granted one free rate limit reset."
    }
  ],
  "available_count": 4
}
```

Note: redeemed/expired credits drop out of the list entirely (after the live claim the
list had 3 entries, not 4 with one `redeemed`).

### Consume (the claim)

`POST /wham/rate-limit-reset-credits/consume`

```json
{
  "redeem_request_id": "<client-generated UUID v4>",
  "credit_id": "RateLimitResetCredit_…"
}
```

- `redeem_request_id` — **idempotency key**, a plain UUID v4 minted by the client
  (`Uuid::new_v4().to_string()` in the TUI). The CLI generates one key per credit shown in
  its picker and **reuses the same key when the user retries after an error**, so a retry
  can never burn a second credit; the server replies `already_redeemed`, which the CLI
  treats as success.
- `credit_id` — optional. When present the server redeems exactly that credit; when
  omitted the server picks one. The CLI always sends it (it sorts available credits by
  soonest `expires_at` and lets the user pick; it only omits `credit_id` in a fallback
  path when the detail list couldn't be fetched).

Response (HTTP 200 even for the "failure" codes — the outcome is in `code`):

```json
{
  "code": "reset",
  "credit": {
    "id": "RateLimitResetCredit_…",
    "status": "redeemed",
    "redeem_started_at": "2026-07-12T01:47:04.448019Z",
    "redeemed_at": "2026-07-12T01:47:05.162045Z",
    …
  },
  "windows_reset": 2
}
```

`code` values (from `ConsumeRateLimitResetCreditCode` in the CLI):

| code | meaning | credit burned? |
|---|---|---|
| `reset` | success; `windows_reset` = number of windows reset (2 = 5h + weekly) | yes |
| `already_redeemed` | same `redeem_request_id` was already processed — treat as success | already was |
| `nothing_to_reset` | usage doesn't need a reset right now (CLI shows "Your usage does not need a reset right now.") | no |
| `no_credit` | the targeted credit is no longer available (raced away / expired), or none available at all | no |

The consume response's `credit` object is richer than the CLI's own struct decodes — it
carries `redeem_started_at` / `redeemed_at` / `profile_*` fields the CLI ignores.

## Live verification (2026-07-12, Pro plan)

Full verbose log (every request/response, token redacted): kept out of the repo; the run
was a one-shot Python script with hard guards (claim at most one credit, only the
soonest-expiring one, only if it expired within 4 h, explicit `credit_id`).

- Before: 4 credits available; 5h window 96% used (reset in ~25 min), weekly 52% used
  (reset in ~6 days). Target credit expired 2.18 h later.
- `POST …/consume` with a fresh UUID + explicit `credit_id` → HTTP 200,
  `code: "reset"`, `windows_reset: 2`, credit `status: "redeemed"`. Round-trip ~1.1 s
  (`redeem_started_at` → `redeemed_at` ≈ 0.7 s server-side).
- After (fetched ~1 s later): both the 5h and weekly windows read **0% used** with full
  window durations (`reset_after_seconds` = 18000 / 604800), `available_count` = 3, and
  the redeemed credit no longer appears in the list. The reset also zeroed the windows of
  the `additional_rate_limits` entry (the model-specific limit was already 0%, so this is
  suggestive, not proven).

## Implementation notes used by OpenUsage

- The claim is a single POST on infrastructure OpenUsage already talks to; auth, headers,
  and account id handling are identical to `CodexUsageClient`'s existing calls.
- Mint the `redeem_request_id` UUID **when the user is shown the claim affordance** (per
  credit), persist it for the duration of the interaction, and reuse it on retry — that is
  the CLI's double-spend protection and we should copy it exactly.
- Always pass an explicit `credit_id`; default the selection to the soonest-expiring
  available credit (the CLI's sort order).
- Treat `already_redeemed` as success; surface `nothing_to_reset` as an informational
  message (credit is *not* lost); on `no_credit` with a `credit_id`, refresh the list —
  the credit raced away.
- This is an irreversible, user-visible spend of a scarce grant — the UI must be an
  explicit, deliberate user action (the CLI uses a picker + confirmation flow), never
  automatic.
- After a successful claim, refresh usage + the credit list immediately: the current Weekly
  meter and the decremented credit count should reflect the result right away.
