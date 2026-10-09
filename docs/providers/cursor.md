# Cursor

Tracks your Cursor plan usage using the login from the Cursor app.

## What it tracks

| Metric | Meaning |
|---|---|
| Total Usage | Plan usage for the billing cycle (percent or dollars; included request count vs. cap on request-based Enterprise accounts) |
| Cursor Models | Usage percent for Cursor's own models, including Cursor Grok and Composer |
| Other Models | Usage percent for other models |
| Grok Bot | Grok Bot weekly usage percent and reset countdown; enabled by default |
| Extra Usage | On-demand spend; user-scoped when available, otherwise the team aggregate; shown as a meter when Cursor returns a limit |
| Requests | Optional copy of the included request count vs. cap for custom layouts |
| Credits | Credit balance left from grants and prepaid account balance |

Teams seats with two usable model-pool percentages use those percentages instead of the legacy
included-dollar cap. Total Usage uses Cursor's structured total percentage when supplied; it is
unavailable when Cursor supplies only the two pools. Older team accounts without usable pool data
keep their dollar meter, including accounts that return zero placeholders beside positive spend.

When Cursor reports your plan name, OpenUsage shows it beside the provider name.

Grok Bot has its own usage allowance, separate from Cursor's normal billing-cycle meter. Its widget
is enabled by default in Cursor's On Demand section. It uses your existing Cursor login, so signing
into the Grok CLI is not required.

## Where credentials come from

Just be signed into the Cursor app. OpenUsage reads Cursor's local state database (and its keychain entries) for the session tokens; refreshed tokens are persisted back. Nothing extra to install or configure.

## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage export. OpenUsage uses the exported token counts and shared model pricing to estimate the cost locally. Cursor's export may occasionally arrive late, so the newest figures can lag behind current activity. OpenUsage leaves isolated malformed rows out instead of silently counting broken values as zero.

Parsed rows are kept on this Mac, one file per Cursor account. Each refresh downloads a single slice, and that slice still has to finish within 20 seconds. Once the last 30 days are cached, the slice runs from six hours before the newest cached event through now, and those overlapping rows replace the cached ones. Until the window is full, each refresh fetches one missing calendar day, newest first. A day that still exceeds 20 seconds is retried as a smaller piece next time. A timeout, a non-2xx response, or a body that does not end on a complete record leaves the cached rows unchanged, and the spend tiles still render from them. A response with no rows does not delete the overlap. Live plan usage still updates when the export fails. Each failure is recorded in the diagnostic log without including the exported usage data.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type; missing metrics simply show "No data".
- **Optional lookup failed** — Grok Bot, plan, credit-grant, prepaid-balance, and request-fallback failures stay nonfatal when primary usage is available. OpenUsage records fixed, credential-free reasons in the diagnostic log.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage and `DashboardService/GetSandUsageStatus` for Grok Bot), combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise/team accounts, Stripe balance at `cursor.com/api/auth/stripe`, and the usage-events CSV export at `cursor.com/api/dashboard/export-usage-events-csv`. The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend; neither REST response is treated as the whole account snapshot by itself. The primary dashboard usage request refreshes the token and retries once after a 401/403; optional endpoint failures stay nonfatal when the other fallback response is usable and are recorded in the diagnostic log. Per-day spend imputation uses exported token counts priced through the shared [model pricing](../pricing.md); Cursor-native models (`auto`, `composer-*`, …) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).
