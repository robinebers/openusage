# AGENTS.md

OpenUsage is a SwiftPM-based SwiftUI menu-bar app for macOS that shows AI provider usage widgets (Claude, Codex, Cursor, Grok, Devin, and more).

This file documents the engineering conventions for the project. Read it before contributing.

## Agent Instructions

AGENTS.md is the source of truth for agent instructions in this repository. CLAUDE.md files may only point to the nearest AGENTS.md file with `@AGENTS.md`; do not add guidance, duplicate instructions, or project rules to CLAUDE.md.

> **Repository note:** This is the native Swift edition of OpenUsage. Active development happens on the `main` branch.

## Rollout: Tauri to Swift (read first)

This Swift edition replaces the original Tauri app. Both editions stay in the same GitHub repo and remain independent.
- The `main` branch is the active Swift development line; it ships the Swift edition via `.github/workflows/release.yml` (Sparkle appcast on `gh-pages`).
- The Tauri edition is preserved on `tauri-legacy`. Its final release is `v0.6.28`, which shows the migration banner.

### Guardrails (do not break)
- Version lanes: Swift owns `0.7.x` and up; Tauri stays on `0.6.x`. Never use a `0.6.x` number here.
- Keep every Swift release marked as a GitHub pre-release until the owner explicitly approves the public flip. For now cut only `-beta.N` tags (Early Access) - `release.yml` marks those pre-release automatically. A plain stable Swift tag becomes GitHub "Latest"; when doing that public flip, carry forward the final Tauri `latest.json` so older Tauri installs can still update to `v0.6.28`. See the release-swift skill.
- Never leave a release in Draft, and never ship blank notes: the release-swift skill generates the changelog and verifies the published release after every cut.
- The Tauri edition is frozen and stays in the repo forever. Do not cut another Tauri release unless there is an emergency.

### Phases
(1) private Swift testing via Early Access, (2) final Tauri goodbye release `v0.6.28`, (3) make Swift the default `main` branch and preserve old Tauri as `tauri-legacy`, (4) flip Swift public when owner-approved by cutting a non-prerelease Swift tag.

## Architecture

- SwiftPM executable target; SwiftUI content hosted in an AppKit-owned `NSStatusItem` + `NSPopover`.
- Swift 6 with strict concurrency.
- Providers implement the small `ProviderRuntime` protocol: an auth store reads credentials already on the user's machine, a usage client calls the provider's API, and a mapper normalizes the response into `MetricLine` values. The UI renders those normalized values.
- See `docs/` for behavior docs and the developer docs (architecture overview, adding a provider).

## Running / Testing Changes

- There is no hot reload. The app is a long-lived menu-bar process, so **every code change requires a full rebuild and restart of the running app** to take effect — kill the running instance, rebuild, and relaunch before testing.

## Documentation

- Logic changes must update any docs in `docs/` that describe the affected behavior.
- Keep docs simple, less-technical, and easy to skim; exclude visual design details.

## Code Conventions

- Add a regression test when fixing a bug, where it fits.
- Keep files under ~500 LOC; split or refactor as needed.
- No new dependencies without justification.
- Follow the existing per-provider folder structure when adding a provider.

## Error Handling

Always fail loudly into error logging and show friendly errors to the user. Do not add silent fallbacks that hide real problems. Only validate at system boundaries (user input, external APIs); trust internal code and framework guarantees.

## UI

- Use title case for any hardcoded copy used as a title.
- Match the existing design language; OpenUsage has a specific look and feel.
- Only add tooltips (`hoverTooltip`) when explicitly asked to. Don't add them proactively to new controls.
