# Local HTTP API

OpenUsage exposes a read-only HTTP API on the loopback interface so other local apps can consume the same usage data shown in the menu bar.

**Base URL:** `http://127.0.0.1:6736`

The server starts automatically with the app. If the port is already in use, the feature is silently disabled for that session.

## Routes

### `GET /v1/usage`

Returns the latest snapshots for all **enabled** providers, in your dashboard order.

- **200 OK** — JSON array (may be empty `[]` if nothing has been fetched yet).

### `GET /v1/usage/:providerId`

Returns the latest snapshot for one provider. Works for disabled providers too.

- **200 OK** — JSON object.
- **204 No Content** — provider is known but has no snapshot yet.
- **404 Not Found** — provider ID is unknown.

### Everything else

Methods other than `GET`/`OPTIONS` return **405**; unknown routes return **404**. When the server is already handling its maximum of 16 concurrent connections, requests get **503** — back off and retry.

## Response shape

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
