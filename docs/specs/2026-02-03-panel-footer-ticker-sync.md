# Panel footer ticker sync

Date: 2026-02-03

## Goal
- Ensure countdown syncs immediately when `autoUpdateNextAt` changes.

## Change
- Add optional `resetKey` to `useNowTicker` and include it in effect deps.
- Pass `resetKey: autoUpdateNextAt` in `PanelFooter`.

## Non-goals
- No behavior changes elsewhere.
