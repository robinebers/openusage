# Cursor Enterprise Included and On-Demand Usage

## Problem

Cursor Enterprise accounts can return no usable `planUsage` from
`GetCurrentPeriodUsage`. OpenUsage then returns early with only the legacy
request-based `Requests` line. That line is optional and disabled by default,
so the enabled Cursor widgets all render `No data` even when `/api/usage`
contains a valid included-request allowance.

The existing fallback also cannot show included requests and on-demand spend
at the same time because it chooses one response and returns before the other
REST data and usage history are appended.

## Observed API shapes

A live Enterprise account was checked on 2026-07-13 with identifiers and exact
account totals omitted:

- `GetCurrentPeriodUsage`: billing-cycle fields only; no `enabled` or
  `planUsage`.
- `GetPlanInfo`: `planName = Enterprise`.
- `GET /api/usage`: `gpt-4.numRequests` and a positive
  `gpt-4.maxRequestUsage`, plus `startOfMonth`.
- `GET /api/usage-summary`: ISO billing-cycle bounds,
  `membershipType = enterprise`, `limitType = team`, structured percentages in
  `individualUsage.plan`, a user-scoped `individualUsage.onDemand`, and a
  team-scoped `teamUsage.onDemand`. This response did not contain
  `teamUsage.pooled` or `individualUsage.overall`.

## Required behavior

1. Fetch both usage-summary and request-based usage for the existing strict
   Enterprise/team fallback.
2. Use a valid request allowance as the existing default `Total Usage` meter
   and keep the optional `Requests` meter for backwards compatibility.
3. Prefer user-scoped on-demand usage over the team aggregate; use the team
   bucket only when the user bucket is unavailable.
4. Map structured Auto/API percentages from `individualUsage.plan`.
5. Fall back to the known pooled/overall usage-summary variants when request
   counts are unavailable.
6. Append Cursor usage-history rows after fallback mapping, as on the normal
   usage path.
7. Add no widget IDs and change no layout defaults.

## Acceptance checks

- A live-shaped Enterprise fixture renders included request usage, Auto/API
  percentages, and the individual on-demand dollar cap together.
- The team on-demand aggregate does not replace a valid individual cap.
- A pooled usage-summary fixture still maps to Total Usage.
- Request-only Enterprise responses retain the previous Requests output while
  also populating the default Total Usage widget.
- When neither REST response has a usable meter, the existing friendly
  fallback error remains visible.
- The full Swift test suite and release build pass, followed by a rebuild and
  launch against the live Enterprise account.
