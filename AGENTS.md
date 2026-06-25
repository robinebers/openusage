# AGENTS.md

OpenUsage is a SwiftPM-based SwiftUI menu-bar app for macOS that shows AI provider usage widgets (Claude, Codex, Cursor, Grok, Devin, and more).

This file documents the engineering conventions for the project. Read it before contributing.

## Agent Instructions

AGENTS.md is the source of truth for agent instructions in this repository. CLAUDE.md files may only point to the nearest AGENTS.md file with `@AGENTS.md`; do not add guidance, duplicate instructions, or project rules to CLAUDE.md.

> **Repository note:** This is the native Swift edition of OpenUsage. Active development happens on the `swift` branch.

## Rollout: Tauri to Swift (read first)

This Swift edition is replacing the original Tauri app. Until the cutover, both editions ship from the same GitHub repo and must stay independent.
- This (`swift`) branch is the active development line; it ships the Swift edition via `.github/workflows/release.yml` (Sparkle appcast on `gh-pages`).
- The Tauri edition still ships from `main` via `publish.yml` and auto-updates from GitHub's "Latest" release.

### Guardrails (do not break)
- Version lanes: Swift owns `0.7.x` and up; Tauri stays on `0.6.x`. Never use a `0.6.x` number here.
- Keep every Swift release marked as a GitHub pre-release until the owner explicitly approves the public flip. For now cut only `-beta.N` tags (Early Access) - `release.yml` marks those pre-release automatically. A plain stable Swift tag becomes GitHub "Latest" and breaks the Tauri updater. See the release-swift skill.
- Never leave a release in Draft, and never ship blank notes: the release-swift skill generates the changelog and verifies the published release after every cut.
- To cut the one final Tauri "goodbye" release, switch to `main` and follow its release-tauri skill. The Tauri edition is frozen and stays in the repo forever.

### Phases
(1) private Swift testing via Early Access, (2) final Tauri goodbye release from `main`, (3) flip Swift public (owner-approved; drops pre-release), (4) make `swift` the default branch and freeze the old Tauri `main` as `tauri-legacy`.

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
