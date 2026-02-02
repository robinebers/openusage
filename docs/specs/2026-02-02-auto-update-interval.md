# Spec: Probe Auto-Update Interval

## Summary
Persisted setting for probe auto-update frequency (5/15/30/60 minutes). Interval change resets timer. Auto-updates do not trigger manual cooldown. Settings shows live countdown + helper text.

## Goals
- Persist interval setting with default 15 minutes.
- Auto-update loop uses enabled plugins; resets on interval or plugin changes.
- Auto-update does not set manual cooldown timestamps.
- Settings UI exposes 4 radio-style options.
- Settings UI shows next auto-update countdown and description.
- Manual refresh resets auto-update schedule.

## Non-goals
- Per-plugin intervals.
- Manual refresh behavior changes beyond timer reset.

## Plan
- Add load/save helpers and type in `src/lib/settings.ts` + tests.
- Load interval in `src/App.tsx`, store in state, add interval effect.
- Reset auto-update schedule on manual refresh.
- Add settings UI section with buttons, countdown, and helper text.

## Acceptance
- Interval persists across restart.
- Changing interval clears prior timer and starts new schedule.
- Auto-updates show loading state without manual cooldown.
- Countdown updates live and resets when interval changes.
- Manual refresh resets the countdown schedule.
