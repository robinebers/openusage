2026-02-09

# Windows updater status

## Goal
- Make Windows auto-update production-ready once signing is configured.

## Current state
- Updater plugin is enabled and publishes `latest.json` for Windows builds.
- Windows signing is not configured in CI.

## Decision
- Treat Windows auto-update as test-only until Authenticode signing is added.

## Follow-up
- Add Windows code signing to publish workflow before enabling production updates.
