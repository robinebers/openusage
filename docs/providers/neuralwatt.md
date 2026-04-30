# Neuralwatt

> Uses the Neuralwatt quota API with a user-provided API key.

## Overview

- **Protocol:** HTTPS (JSON)
- **Endpoint:** `GET https://api.neuralwatt.com/v1/quota`
- **Auth:** `Authorization: Bearer <api_key>`
- **Env var:** `NEURALWATT_API_KEY`

## Authentication

The plugin reads `NEURALWATT_API_KEY` from the environment. If the key is missing, it throws:

- `Neuralwatt API key missing. Set NEURALWATT_API_KEY.`

## Data Source

Request:

```http
GET /v1/quota HTTP/1.1
Host: api.neuralwatt.com
Authorization: Bearer <api_key>
Accept: application/json
User-Agent: OpenUsage
```

Expected payload fields:

- `balance.credits_remaining_usd`, `balance.total_credits_usd`, `balance.credits_used_usd`
- `balance.accounting_method` (e.g. `"energy"`, `"token"`)
- `subscription.plan`, `subscription.status`, `subscription.billing_interval`
- `subscription.current_period_start`, `subscription.current_period_end`
- `subscription.kwh_included`, `subscription.kwh_used`, `subscription.kwh_remaining`
- `subscription.auto_renew`, `subscription.in_overage`

## Usage Mapping

- **Subscription** (progress line): `kwh_used` / `kwh_included` in kWh. Shown only when subscription is present and `kwh_included > 0`.
- **Balance** (progress line): `credits_used_usd` / `total_credits_usd` in dollars. Shown only when `total_credits_usd > 0`.
- **Method** (badge): `accounting_method`, capitalized. Hidden when absent.

The **Subscription** line includes `resetsAt` and `periodDurationMs` from the subscription period dates when available; the **Balance** line does not.

## Output

- **Plan**: from `subscription.plan`, capitalized
- **Subscription** (overview progress line):
  - `format`: count with `kWh` suffix
  - `used`: `kwh_used`
  - `limit`: `kwh_included`
  - `resetsAt`: from `current_period_end`
  - `periodDurationMs`: `current_period_end` – `current_period_start`
- **Balance** (detail progress line):
  - `format`: dollars
  - `used`: `credits_used_usd`
  - `limit`: `total_credits_usd`
- **Method** (badge): capitalized `accounting_method`

## Errors

| Condition | Message |
|---|---|
| Missing API key | `Neuralwatt API key missing. Set NEURALWATT_API_KEY.` |
| HTTP 401/403 | `Invalid API key. Check NEURALWATT_API_KEY.` |
| Non-2xx | `Request failed (HTTP {status}). Try again later.` |
| Network failure | `Request failed. Check your connection.` |
| Unparseable payload | `Response invalid. Try again later.` |
