# Spec: Probe Auto-Update Interval

## Summary
Persisted setting for probe auto-update frequency (5/15/30/60 minutes). Interval change resets timer. Footer shows live countdown.

## Goals
- Persist interval setting with default 15 minutes.
- Auto-update loop uses enabled plugins; resets on interval or plugin changes.
- Settings UI exposes 4 radio-style options.
- Footer shows "Next update in Xm" countdown.

## Non-goals
- Per-plugin intervals.

## Plan
- Add load/save helpers and type in `src/lib/settings.ts` + tests.
- Load interval in `src/App.tsx`, store in state, add interval effect.
- Add settings UI section with interval buttons.
- Add countdown display to footer.

## Acceptance
- Interval persists across restart.
- Changing interval clears prior timer and starts new schedule.
- Auto-updates show loading state.
- Countdown in footer updates live and resets when interval changes.
