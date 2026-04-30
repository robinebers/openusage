# CrofAI

> Uses the CrofAI Usage API with a user-provided API key.

## Overview

- **Protocol:** HTTPS (JSON)
- **Endpoint:** `GET https://crof.ai/usage_api/`
- **Auth:** `Authorization: Bearer <api_key>`
- **Data:** credit balance, daily requests remaining

## Authentication

Set the `CROFAI_API_KEY` environment variable:

```bash
export CROFAI_API_KEY="your-api-key-here"
```

The key is read from the environment at probe time. Restart OpenUsage after setting it.

## Data Source

Request:

```http
GET /usage_api/ HTTP/1.1
Host: crof.ai
Authorization: Bearer <api_key>
Accept: application/json
```

Response:

```json
{
  "credits": 12.3456,
  "usable_requests": 321,
  "requests_plan": 500
}
```

| Field | Type | Description |
|---|---|---|
| `credits` | number | Available credit balance (USD) |
| `usable_requests` | number \| null | Requests remaining today (`null` if not on a subscription plan) |
| `requests_plan` | number | Total daily request limit |

## Output

- **Requests** (overview progress line): progress bar showing used requests out of the daily plan (e.g., `179 / 500`); hidden when `usable_requests` is `null`
- **Credits** (overview text line): formatted dollar balance (e.g., `$12.35`)

## Errors

| Condition | Message |
|---|---|
| Missing `CROFAI_API_KEY` env var | `No CROFAI_API_KEY found. Set up environment variable first.` |
| HTTP 401/403 | `API key invalid. Check your CrofAI API key.` |
| Non-2xx | `Usage request failed (HTTP {status}). Try again later.` |
| Network failure | `Usage request failed. Check your connection.` |
| Unparseable or invalid response shape/type | `Usage response invalid. Try again later.` |
