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

When the local Cursor database already supplies the selected login, OpenUsage avoids Keychain reads. Keychain is used when the database has no login or its free account differs from the saved Keychain account.

## Spend history

Today, Yesterday, Last 30 Days, and Usage Trend come from Cursor's usage history—the same data shown on Cursor's Usage page. OpenUsage keeps each day on your Mac, separately for each Cursor account, and re-checks today and yesterday on every refresh. It fills in missing older days in the background within 20 seconds per refresh. A failed or short download never erases stored days. The chart appears once all 30 days are stored; heavy accounts may take a couple of refreshes the first time.

## Troubleshooting

- **"Not logged in" / token errors** — open Cursor and make sure you're signed in, then refresh.
- **Some metrics missing** — Cursor omits fields depending on plan type; missing metrics simply show "No data".
- **Optional lookup failed** — Grok Bot, plan, credit-grant, prepaid-balance, and request-fallback failures stay nonfatal when primary usage is available. OpenUsage records fixed, credential-free reasons in the diagnostic log.

## Under the hood

Connect RPC on `api2.cursor.sh` (dashboard usage and `DashboardService/GetSandUsageStatus` for Grok Bot), combined REST fallback at `cursor.com/api/usage` and `cursor.com/api/usage-summary` for Enterprise/team accounts, Stripe balance at `cursor.com/api/auth/stripe`, and paged usage events at `cursor.com/api/dashboard/get-filtered-usage-events`. The fallback combines the included request allowance with structured percentages and user-scoped on-demand spend; neither REST response is treated as the whole account snapshot by itself. The primary dashboard usage request refreshes the token and retries once after a 401/403; optional endpoint failures stay nonfatal when the other fallback response is usable and are recorded in the diagnostic log. Per-day spend imputation uses usage-event token counts priced through the shared [model pricing](../pricing.md); Cursor-native models (`auto`, `composer-*`, …) come from its supplement layer, which maintainers sync from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md).
