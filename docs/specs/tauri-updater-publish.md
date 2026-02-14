2026-02-02

# Tauri updater + publish workflow

## Goal
- GitHub Releases publishes: bundles + updater manifest for Tauri v2 updater plugin.
- App checks `latest.json` from GitHub Releases and updates safely.

## Source of truth
- Release tag `vX.Y.Z` is the version.
- Must match:
  - `src-tauri/tauri.conf.json` `.version`
  - `src-tauri/Cargo.toml` `[package].version`
  - `package.json` `.version`

## CI definition-of-done
- `publish.yml` builds per target arch and uploads:
  - bundle artifacts (e.g. `.dmg`, `.app.tar.gz`)
  - updater signatures (`.sig`)
  - updater manifest `latest.json`
- `latest.json` contains both macOS arches (sequential matrix run merges platforms).

## Runtime definition-of-done
- `src-tauri/tauri.conf.json` updater `endpoints` points to `.../releases/latest/download/latest.json`.
- Release `latest.json` exists and references the same release’s assets.

## Windows notes
- Windows auto-update requires Authenticode-signed installers.
- Until signing is configured, treat Windows updater as test-only (downloads may be blocked by SmartScreen/UAC).
