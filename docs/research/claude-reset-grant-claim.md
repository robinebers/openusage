# Claude Usage-Limit Reset Grants: How Claiming Works

Protocol reference for claiming one of Anthropic's `cedar_ember` usage-limit reset grants, written
2026-10-18 for issue #1291. OpenUsage claims from the resets popover (`ClaudeProvider+ResetClaim.swift`).

Sources: issue #1291; strings in the local Claude Code 2.1.302 binary; seven public projects that send
the same request (for example `lidge-jun/opencodex` `src/providers/anthropic-reset-grants.ts`,
`router-for-me/Cli-Proxy-API-Management-Center` `src/services/api/claudeResetGrants.ts`, oh-my-pi
`packages/ai/src/usage/claude-reset.ts`). All of those projects test with mocks only. None of them
publishes a real response.

## Reading grants

`GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1` returns a `cedar_ember` block:

```json
{
  "eligible": true, "ineligible_reason": null, "at_limit": false,
  "grants": [
    { "id": "opus55-launch-promax-20260921", "resets_total": 1, "resets_left": 1,
      "starts_at": "2026-09-22T16:00:00+00:00", "ends_at": "2026-10-22T16:00:00+00:00",
      "clears": ["five_hour", "seven_day"], "paused": false, "usable_now": true,
      "use_requires_limit": false }
  ],
  "next_grant_id": "opus55-launch-promax-20260921",
  "cooldown_until": null
}
```

Anthropic decides eligibility by client surface. A User-Agent it doesn't recognize as Claude Code comes
back `eligible: false, ineligible_reason: "surface"`. OpenUsage rejects the whole block when a grant
is malformed (no string `id` or numeric `resets_left`), like Claude Code does.

## Claiming

`POST https://api.anthropic.com/api/organizations/{orgUUID}/reset_rate_limits`

Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
`User-Agent: claude-cli/<version> (external, cli)`, `Content-Type: application/json`. Timeout 25s.

```json
{ "program": "cedar_ember", "grant_id": "<next_grant_id>", "request_id": "<stable per confirm>" }
```

- `orgUUID` is `organization.uuid` from `GET /api/oauth/profile` for the same token.
- `grant_id` matches `^[a-z0-9_-]{1,40}$`. OpenUsage always sends `next_grant_id`.
- `request_id` matches `^[A-Za-z0-9_-]{1,64}$`. The popover mints one UUID per confirm and reuses it
  for every retry and every credential fallback, so a retry can't spend twice.
- Claude Code refreshes OAuth before claiming. OpenUsage refreshes only a token that is about to expire.

Response: `{ result, reason, resets_left, cleared, weekly_resets_at, cooldown_until }`.

| `result` / `reason` | Meaning | OpenUsage outcome |
|---|---|---|
| `reset` | Limits cleared | Success |
| `already_used` | This request id already spent the grant | Success |
| `not_limited` | Nothing to reset; nothing spent | Nothing to reset |
| `ineligible`; `unavailable` + `no_grant` / `unknown_grant` / `not_next_grant` | Refused; nothing spent | No longer available |
| `reset_unconfirmed`, `stamp_indeterminate` | May still be going through | Unconfirmed |
| `cooldown`; `unavailable` + `paused` / `low_priority_active` | Can't be used right now | Unavailable now (with `cooldown_until`) |
| `not_authorized`, `no_profile_scope`, `grant_id_required`, anything else, non-2xx | Error | Failed |

Claude Code's copy for `already_used` distinguishes "Your earlier reset went through after all" (a retry of
an unsettled claim) from "That reset was already used, nothing changed". OpenUsage mints a fresh request
id per confirm, so `already_used` can only answer its own earlier attempt.

After any outcome except Failed, OpenUsage drops its hourly grants answer and forces a refresh, so the
row doesn't show a spent reset for an hour.

## Verification

1. Mocked tests: `Tests/OpenUsageTests/ClaudeResetClaimTests.swift`.
2. Free live dry run, opt-in with `OPENUSAGE_LIVE_CLAUDE_CLAIM_DRYRUN=1`: sends the real request with
   `grant_id: "openusage-dryrun-probe"`, which matches no grant. Run live on 2026-10-18 against an
   account holding one unspent grant. The server validated `grant_id` and spent nothing:

   ```json
   {"result":"ineligible","reason":"unknown_grant","reset":false,"grant_id":"openusage-dryrun-probe",
    "resets_left":null,"cleared":[],"weekly_resets_at":null,"cooldown_until":null}
   ```

   An unknown grant comes back as `result: "ineligible"`, not `unavailable`, and the response carries a
   `reset` boolean and echoes `grant_id`. Both map to "no longer available".
3. First real claim, made from the resets popover on 2026-10-18 with an anytime grant while not at a
   limit. HTTP 200:

   ```json
   {"result":"reset","reason":null,"reset":true,"grant_id":"opus55-launch-promax-20260921","resets_left":0,
    "cleared":["five_hour","seven_day","seven_day_overage_included"],
    "weekly_resets_at":"2026-10-20T20:00:00+00:00","cooldown_until":"2026-10-18T11:56:45.910978+00:00"}
   ```

   A successful claim also starts a short `cooldown_until`, about two minutes here. `cooldown_until`
   carries fractional seconds.
