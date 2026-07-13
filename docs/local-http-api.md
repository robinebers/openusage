# Local HTTP API

OpenUsage exposes a read-only HTTP API on the loopback interface so other local apps can consume the same usage data shown in the menu bar.

**Base URL:** `http://127.0.0.1:6736`

The server starts automatically with the app. If the port is already in use, the feature is silently disabled for that session.

## Routes

### `GET /v1/limits`

Returns a machine-facing envelope for all **enabled** providers. Providers and resources are keyed by
stable IDs; values are raw scalars with explicit units. This is the preferred route for new integrations
and the exact format printed by the `openusage` CLI.

### `GET /v1/limits/:providerId`

Returns the same envelope containing one provider. It works for disabled providers too.

- **200 OK** — limits envelope, including an `errors` entry when a refresh failed.
- **204 No Content** — provider is known but has neither a snapshot nor a recorded refresh failure yet.
- **404 Not Found** — provider ID is unknown.

### `GET /v1/usage`

Returns the legacy UI-oriented snapshots for all **enabled** providers, in your dashboard order. Existing
consumers remain supported while this route is deprecated; new consumers should use `/v1/limits`.

Both routes read the same rendered provider snapshots. When iCloud Sync is on, that means they both see
the same iCloud-combined usage as the dashboard; `/v1/usage` returns the old UI-oriented shape, while
`/v1/limits` projects the data into stable resource IDs and raw scalar values.

- **200 OK** — JSON array (may be empty `[]` if nothing has been fetched yet).

### `GET /v1/usage/:providerId`

Returns the latest snapshot for one provider. Works for disabled providers too.

- **200 OK** — JSON object.
- **204 No Content** — provider is known but has no snapshot yet.
- **404 Not Found** — provider ID is unknown.

### Everything else

Methods other than `GET`/`OPTIONS` return **405**; unknown routes return **404**. When the server is already handling its maximum of 16 concurrent connections, requests get **503** — back off and retry.

## Limits response shape

```jsonc
{
  "schema": "openusage.limits.v1",
  "generatedAt": "2026-07-13T01:40:00.000Z",
  "providers": {
    "codex": {
      "displayName": "Codex",
      "plan": "Pro 20x",
      "fetchedAt": "2026-07-13T01:39:30.000Z",
      "expiresAt": "2026-07-13T01:44:30.000Z",
      "stale": false,
      "resources": {
        "session": {
          "kind": "consumption",
          "unit": "percent",
          "used": 42,
          "limit": 100,
          "remaining": 58,
          "utilization": 0.42,
          "resetsAt": "2026-07-13T06:00:00.000Z",
          "windowSeconds": 18000
        },
        "credits": {
          "kind": "balance",
          "unit": "credits",
          "available": 821
        }
      }
    }
  },
  "errors": []
}
```

`kind` is `consumption` (`used`) or `balance` (`available`). Bounded consumption also carries `limit`,
`remaining`, and a 0–1 `utilization`. Reset, window, expiry-list, and `estimated` fields appear only when
the provider supplies that meaning. A provider or resource with no current value is omitted rather than
invented as zero. `expiresAt` is always `fetchedAt` plus the same five-minute freshness interval used by
the app and CLI; `stale` says whether that instant has passed. Refresh failures appear in `errors` as
`{"providerId":"…","message":"…"}` while a last-good provider snapshot remains available.

### Public resources

| Provider | Resource keys |
| --- | --- |
| Claude | `session`, `weekly`, `sonnet`, `fable`, `extraUsage` |
| Codex | `session`, `weekly`, `spark`, `sparkWeekly`, `credits`, `creditValue`, `rateLimitResets` |
| Cursor | `totalUsage`, `autoUsage`, `apiUsage`, `onDemand`, `requests`, `credits` |
| Antigravity | `geminiSession`, `geminiWeekly`, `nonGeminiSession`, `nonGeminiWeekly` |
| Copilot | `premiumCredits`, `extraUsage`, `orgCredits`, `orgSpend`, `chat`, `completions` |
| Devin | `daily`, `weekly`, `extraUsageBalance` |
| Grok | `weekly` |
| OpenCode | `session`, `weekly`, `monthly` |
| OpenRouter | `credits`, `balance`, `keyLimit` |
| Z.ai | `session`, `weekly`, `webSearches` |

Charts, colors, subtitles, formatted badges, layout state, and historical spend periods stay out of this
contract. Codex's combined Credits UI row becomes two scalar resources: `credits` and `creditValue`.

## Legacy usage response shape

```jsonc
{
  "providerId": "claude",
  "displayName": "Claude",
  "plan": "Team 5x",
  "lines": [
    {
      "type": "progress",
      "label": "Session",
      "used": 42.0,
      "limit": 100.0,
      "format": { "kind": "percent" },          // or "dollars", or "count" (+ "suffix")
      "resetsAt": "2026-03-26T13:00:00.161Z",   // optional
      "periodDurationMs": 18000000,             // optional
      "color": null
    },
    {
      "type": "text",
      "label": "Today",
      "value": "$5.17 · 9.2M tokens",
      "color": null,
      "subtitle": null
    },
    {
      "type": "badge",
      "label": "Pay as you go",
      "text": "2500 cap",
      "color": "#22c55e",
      "subtitle": null
    },
    {
      "type": "barChart",
      "label": "Usage Trend",
      "points": [
        { "label": "Mar 25", "value": 1200000.0, "valueLabel": "1.2M tokens" },
        { "label": "Mar 26", "value": 2400000.0, "valueLabel": "2.4M tokens" }
      ],
      "note": "Estimated from local Claude logs at API rates.",
      "color": null
    }
  ],
  "fetchedAt": "2026-03-26T11:16:29.000Z"
}
```

Line types are `progress`, `text`, `badge`, and `barChart`. A `barChart` line carries a `points` array — one `{ label, value, valueLabel? }` per day, oldest first — plus an optional `note`; `value` is the day's token count, `valueLabel` its pre-formatted readout, and `label` a localized month/day (e.g. "Mar 25"). `fetchedAt` is when the snapshot was last fetched successfully (ISO 8601).

The in-app model breakdown shown when hovering spend rows is not included in this API yet. Spend rows continue to serialize as the same `text` lines so existing local integrations keep their current shape.

## Errors

```json
{ "error": "provider_not_found" }
```

Codes: `provider_not_found`, `not_found`, `method_not_allowed`, `server_busy`.

## CORS and privacy

All responses include permissive CORS headers (`Access-Control-Allow-Origin: *`, methods `GET, OPTIONS`). `OPTIONS` requests return **204** for preflight.

The server only listens on the loopback interface (`127.0.0.1`), so it is not reachable from other machines on your network. Because the CORS header is permissive, though, a web page open in your browser can read your usage snapshots from this API while the app is running. The data exposed is the same usage numbers shown in the menu bar — no credentials or tokens are ever served. This matches the original app's behavior so existing integrations keep working.

## Caching behavior

The API serves whatever the app is showing: only successful fetches replace data, so a failed refresh never blanks the API — you keep getting the last good snapshot. See [Refreshing & caching](refreshing.md).
