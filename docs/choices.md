# Choices

## 2026-05-13

- Fireworks billing export now uses a temporary `~/.fireworks/auth.ini` for the `firectl` subprocess instead of passing the API key on argv.
- Fireworks zero-valued quotas and zero-token billing windows are treated as real data, not as missing data.
- Fireworks billing export is bounded with a 15 second timeout so one stuck CLI run cannot wedge probe batches.
