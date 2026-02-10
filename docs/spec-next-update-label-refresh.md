# Spec: Next update label triggers global refresh

## Goal
- Clicking the "Next update in ..." footer label triggers a manual refresh of all eligible enabled providers.
- Each refreshed provider enters the existing manual refresh cooldown.

## Non-goals
- No new UI settings or tray behavior changes.
- No redesign of provider refresh hover affordance.

## Behavior
- Footer label is clickable when auto-update is scheduled.
- Clicking triggers a probe batch for enabled providers that are not in cooldown.
- If all enabled providers are within cooldown, the click is a no-op.
- Auto-update schedule is reset when a manual global refresh starts.

## Analytics
- Reuse existing provider refresh tracking for per-provider refreshes only (no new event).

## Tests
- Add coverage for clicking the footer label to start a batch for enabled providers.
