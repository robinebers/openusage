# AGENTS.md

OpenUsage is a SwiftPM-based macOS menu-bar app that shows the usage limits of the AI coding accounts a
user adds within the app (Claude, Codex, Cursor, Copilot, Antigravity, Devin, Grok, Ollama, OpenCode,
OpenRouter, Z.ai).

This file documents the engineering conventions for the project. Read it before contributing.

## Agent Instructions

AGENTS.md is the source of truth for agent instructions in this repository. CLAUDE.md files may only
point to the nearest AGENTS.md file with `@AGENTS.md`; do not add guidance, duplicate instructions, or
project rules to CLAUDE.md.

> **Repository note:** This is the native Swift edition of OpenUsage. Active development happens on the
> `main` branch. (NOT the legacy Tauri version which now sits in the `tauri-legacy` branch)

## Releases

`main` is the active development line; it ships via `.github/workflows/release.yml` (Sparkle appcast
on `gh-pages`). Cut releases with the release-swift skill.

### Guardrails (do not break)
- Versions are `0.7.x` and up. Never reuse a `0.6.x` number — those are the original edition's released
  tags, now frozen on the `tauri-legacy` branch (final release `v0.6.28`).
- **Never increase the version number on your own initiative — always ask for explicit approval
  first.** The version is a deliberate owner decision: propose the number and wait for explicit
  sign-off before tagging or cutting a release.
- Beta releases use `-beta.N` tags and stay GitHub pre-releases on Sparkle's beta channel. Stable
  releases use plain tags and become GitHub "Latest".
- Stable releases must carry forward the legacy `latest.json` so any remaining `0.6.x` installs can
  still update to `v0.6.28`. `release.yml` handles this; verify it with the release-swift skill.
- Never leave a release in Draft, and never ship blank notes: the release-swift skill generates the
  changelog and verifies the published release after every cut.
- The appcast URL and the Sparkle public key in `script/release.sh` identify the app to every installed
  copy. Never change them.

## Architecture

- Swift 6 with strict concurrency; SwiftUI content hosted in an AppKit-owned `NSStatusItem` and a
  key-capable `NSPanel`.
- `AccountStore` persists account metadata. `CredentialVault` stores credentials in the app's own
  Keychain service.
- Users initiate all provider sign-ins from the popover's Accounts screen. Never discover credentials
  or accounts from other tools, and never read their files, Keychain items, SQLite databases, or
  environment variables.
- Each account has one provider runtime. The runtime calls the provider API and maps its response to
  dashboard metrics. Do not add log scanning, spend estimates, or external pricing; the one exception
  is ChatGPT's credits, priced at 4¢ each in `CodexUsageMapper`.
- The dashboard shows provider-supplied limits and dollar values only. Provider and account order is
  the user's saved order; a provider's first account goes to the bottom, and a new account goes to the
  bottom of its provider's accounts, in the order they were added. Never sort providers or accounts by
  catalog order or name.
- Never rebuild `AppContainer` or the status item on an account change; the account observer swaps
  runtimes in place.
- See `docs/` for behavior docs and the developer docs (architecture overview, adding a provider).

## Providers

Provider sign-in and usage code lives under `Sources/OpenUsage/Providers/<Name>/` and
`Sources/OpenUsage/Services/`. Use `ProviderLogin` for sign-in and `AccountProviderRuntime` for
account-scoped refresh. Provider API failures should surface as friendly account-specific errors
without logging credentials or response bodies. See `docs/adding-a-provider.md`.

**Metric placement defaults:** every metric starts shown. When adding or changing a metric, confirm its
two defaults with the owner before choosing — never pick silently:
1. starred into the menu bar (`.pinnedByDefault()` on its descriptor in `widgetDescriptors`),
2. order (within an account, the `widgetDescriptors` declaration order).

## Running / Testing Changes

```sh
swift build
script/test_quiet.sh [--filter <Suite>]
./script/build_and_run.sh verify
```

`script/test_quiet.sh` is the only way to run the tests on a Mac someone is using: the suite hosts real
windows, and the script runs it niced, keeps it from taking the keyboard or the screen, and fails the
run if a test process ever came to the front. The rename-focus tests need a key window, so they skip
unless `OPENUSAGE_FOCUS_TESTS=1`; run them with `swift test --filter InlineRenameFocusTests` on a Mac
nobody is typing on after every change to a header or to renaming, or they rot unseen.

There is no hot reload. The app is a long-lived menu-bar process, so **every code change requires a
full rebuild and restart of the running app** to take effect. The development bundle identifier is
`com.robinebers.openusage.dev`; it never touches the installed app's settings or Keychain items.

## Pull Requests

Every PR description must follow this structure so reviewers can skim it quickly:

- **TL;DR** — open with a one- or two-sentence plain-English summary of the change.
- **What was happening** — plain-English bullet points describing the prior behavior, bug, or gap that
  motivated the change.
- **What this changes** — bullet points describing what the PR actually changes.
- **Heads-up** (optional) — noteworthy things a reviewer or future maintainer should consider (risks,
  follow-ups, trade-offs).
- **Tests** (optional) — how the change was verified.
- **Screenshots** (optional in general, but **required for any PR that makes a visual change**) —
  images of the affected UI after the change.

## Documentation

- Logic changes must update `README.md` and any page in `docs/` that describes the affected behavior.
- Keep docs plain, brief, and easy to skim; exclude visual design details. Remove documentation for
  features that are no longer present.

## Code Conventions

- Keep files under roughly 500 lines; split focused concerns when needed.
- Follow existing Swift formatting and strict-concurrency conventions.
- Validate user input and provider API responses at the boundary; trust internal code and framework
  guarantees.
- Add a focused regression test for behavior changes.
- Do not add dependencies without a clear need.

## Error Handling

Fail loudly: log the error through `AppLog` (unified logging) and show a friendly, account-specific
message to the user. Do not add silent fallbacks that hide real problems. Never log credentials or
response bodies.

## UI

- Use title case for any hardcoded copy used as a title.
- Match the existing macOS design language; OpenUsage has a specific look and feel.
- Only add tooltips (`hoverTooltip`) when explicitly asked to. Don't add them proactively to new
  controls.
