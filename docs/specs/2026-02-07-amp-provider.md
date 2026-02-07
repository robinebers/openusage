# Amp Provider Plugin

**Date:** 2026-02-07
**Status:** Done

## Summary

Add Amp (ampcode.com) as a provider plugin to track free tier usage and individual credits via JSON-RPC API.

## Data Source

Amp exposes a JSON-RPC API at `POST https://ampcode.com/api/internal`. The `userDisplayBalanceInfo` method returns a human-readable balance string containing usage data.

Request:
```json
{
  "method": "userDisplayBalanceInfo",
  "params": {}
}
```

Response varies by user tier:

**Free tier enabled:**
```json
{
  "ok": true,
  "result": {
    "displayText": "Signed in as <user>\nAmp Free: $<remaining>/$<total> remaining (replenishes +$<rate>/hour) [optional: +N% bonus for N more days] - https://ampcode.com/settings#amp-free\nIndividual credits: $<credits> remaining - https://ampcode.com/settings"
  }
}
```

**Paid credits only:**
```json
{
  "ok": true,
  "result": {
    "displayText": "Signed in as <user>\nIndividual credits: $<credits> remaining - https://ampcode.com/settings"
  }
}
```

Parsed fields:
- `remaining` / `total` — dollar amounts (only if Amp Free enabled)
- `hourlyRate` — replenishment rate per hour (only if Amp Free enabled)
- `bonusPct` / `bonusDays` — optional bonus info (promotional, time-limited)
- `credits` — individual credits balance

## Authentication

API key auto-detected from `~/.local/share/amp/secrets.json` (created by Amp CLI on login). Key format: `sgamp_user_{ULID}_{64hex}`.

Sent as `Authorization: Bearer <key>` header.

## Plan Detection

| Condition | Plan |
|-----------|------|
| Free tier present (with or without credits) | `"Free"` |
| Credits only (no free tier) | `"Credits"` |

## Displayed Lines

| Line       | Scope    | Type     | Condition                   | Description                     |
|------------|----------|----------|-----------------------------|---------------------------------|
| Free       | overview | progress | Amp Free enabled            | Dollar amount used vs total     |
| Bonus      | detail   | text     | Amp Free + active promotion | Bonus percentage and duration   |
| Credits    | detail   | text     | Credits > $0                | Individual credits balance      |

Progress line includes `resetsAt` (computed from `used / hourlyRate`) and `periodDurationMs` (24h). `resetsAt` is null when nothing is used or hourly rate is zero.

## Files

- `plugins/amp/plugin.json` — manifest
- `plugins/amp/plugin.js` — implementation
- `plugins/amp/icon.svg` — icon (from https://ampcode.com/press-kit)
- `plugins/amp/plugin.test.js` — tests
- `docs/providers/amp.md` — provider documentation
