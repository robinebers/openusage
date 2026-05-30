# Warp

Tracks AI usage credits for the Warp terminal.

## Data Source

The plugin reads the **AI Credits** quota from Warp's User Defaults System.

- **Domain**: `dev.warp.Warp-Stable`
- **Key**: `AIRequestLimitInfo`

## Prerequisites

- Warp must be installed.
- You must be logged into your Warp account.
- You must have used Warp AI at least once to initialize the local User Defaults System data.
  - If your quota has recently reset, you must use Warp AI again to trigger a local update.

## Parsed Fields

From `AIRequestLimitInfo`:
- `num_requests_used_since_refresh`: used credits
- `limit`: total credit limit
- `next_refresh_time`: reset timestamp

## Displayed Lines

| Line | Scope | Description |
| :--- | :--- | :--- |
| AI Credits | Overview | Total AI credits used in the current billing cycle. Includes reset timer. |

## Errors

| Condition | Message |
| :--- | :--- |
| Key not found in defaults | "No Warp AI usage data found. Ensure Warp is installed and you have used AI at least once. If you have, this may be a plugin bug." |
| Data malformed or incomplete | "Warp AI quota data is malformed. This may be a plugin bug." |
| Data is stale (expired reset time) | "No active Warp AI quota found. Have your credits reset recently? Try using Warp AI once to refresh it." |
