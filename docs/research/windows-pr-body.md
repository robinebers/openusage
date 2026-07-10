## TL;DR

Research spike for a Windows port of OpenUsage: Swift sidecar (`spikes/windows-core`) + WPF shell (`spikes/windows-shell`) with a floating always-on-top metrics strip, tray brand icon, and dark flyout. **No production macOS code paths were changed.**

Screenshots (strip + flyout): see `docs/windows.md` and `docs/research/images/`.

## What was happening

OpenUsage ships as a native macOS menu-bar app. There was no shared, measured answer for what a Windows port costs (toolchain, credentials, UI shell, packaging). Phases 0–6 explored Candidate A (C# shell + Swift core over a named pipe) end to end on a real Windows box.

## What this changes

- Adds `spikes/windows-core` (Swift 6 providers + Win32 shims + `sidecar` product) and `spikes/windows-shell` (tray, floating strip, flyout, 5‑minute refresh, single-instance, autostart toggle, toasts).
- Adds `docs/windows.md`, phase findings / port plan / toolchain notes, and spike-scoped CI workflows.
- Adds `script/build_and_run.ps1` and `script/package_windows.ps1` for an unsigned zip.
- Leaves `Sources/OpenUsage/`, root `Package.swift`, and production `release.yml` untouched.

## Heads-up

- Spike-quality code meant to inform the port plan — **not** a public Windows beta.
- Cold start can be ~30–70s on first sidecar bootstrap; SmartScreen will warn (unsigned).
- Widgets Board / taskbar-pill experiments were tried and removed; findings stay in research docs.
- See `docs/research/windows-pr-readiness.md` for product-beta blockers after this PR.

## Tests

- `swift test` in `spikes/windows-core` (local / spike CI).
- `.\script\build_and_run.ps1 verify` on Windows 11 with live Claude/Codex/Cursor credentials.
- Manual checklist: `docs/research/windows-manual-test-checklist.md`.
