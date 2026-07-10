# Phase 6 Findings — Quality, Docs & Beta Readiness

Status: **COMPLETE (research spike)** — docs, checklist, smoke pass, performance sample, beta assessment. No production tree changes.
Date: 2026-07-10

Machine: `win32` developer box, Swift 6.3.3 `x86_64-unknown-windows-msvc`, .NET 8, VS 2022 Build Tools 17.14.

---

## Executive summary

Phase 6 closes the Windows **research spike** with user/dev documentation, a manual test checklist, smoke results on this machine, one performance sample, and an explicit beta-readiness assessment. The spike demonstrates candidate **A** (WPF shell + Swift sidecar) end to end for three live providers, but **does not** meet the bar for a public Windows beta without signing, production updater, UI parity, remaining providers, and owner decisions from Phase 0.

**UX note (post–Phase 6 polish):** Early experiments (Windows Widgets Board / taskbar weather-style pill) were tried and **removed** from the tree. The surviving shell UX is tray brand icon + **floating always-on-top strip** + dark flyout. See [windows-pr-readiness.md](windows-pr-readiness.md).

**Explicit scope statement:** This worktree contains spikes and research docs only. **`Sources/OpenUsage/`, `Tests/OpenUsageTests/`, root `Package.swift`, and production `release.yml` were not modified.** Nothing from the agent sessions was committed.

---

## Phases 0–5 rollup

| Phase | Deliverable | Outcome |
|---|---|---|
| **0** Core spike | Swift builds on Windows; Grok subset | **GO** — toolchain green; 98 tests → grew in later phases |
| **1** Portability | Inventory + expanded core | [windows-phase1-report.md](windows-phase1-report.md), [windows-portability-inventory.md](windows-portability-inventory.md) |
| **2** Providers | WinCred + winsqlite3; Cursor; e2e harness | **282/282** tests; Claude/Codex/Cursor live on this machine |
| **3** Shell | WPF tray + named-pipe IPC | Candidate A verified with live metrics |
| **4** System | Single-instance, autostart, toasts, logs, sidecar supervisor | WPF build green |
| **5** Release | `build_and_run.ps1`, `package_windows.ps1`, update stub, draft CI | Unsigned zip ~85 MB; `release.yml` untouched |
| **6** Quality/docs | This document + `docs/windows.md` + checklist | Smoke + baselines recorded below |

---

## Smoke test results (2026-07-10)

| Check | Result | Evidence |
|---|---|---|
| Core `swift test` | **287/287 pass** (3 skipped) | Same session as Phase 6 |
| `build_and_run.ps1 verify` | **Pass** | OpenUsageShell running after launch |
| Packaged/staged launch | **Pass** | `dist/windows/OpenUsage/OpenUsageShell.exe` + sidecar |
| Single instance | **Pass** | 1 shell + 1 sidecar after duplicate launch |
| Autostart registry toggle | **Pass** | Enable/disable round-trip; **left OFF** |
| Sidecar snapshot refresh | **Pass** | `smoke-sidecar.ps1`: Claude/Codex/Cursor `status=ok` |
| Shell + sidecar logs | **Pass** | `%LOCALAPPDATA%\OpenUsage\logs\` |
| Toast | **Pass** (prior manual) | Log: `Toast notifier ready`; Test Notification used in Phase 4 |
| External pipe while shell running | **N/A** | Shell holds exclusive pipe client — use sidecar-only smoke |

Full checklist: [windows-manual-test-checklist.md](windows-manual-test-checklist.md).

---

## Performance baselines (one sample)

Measured on this machine after sidecar bootstrap (Claude/Codex/Cursor credentials present).

| Metric | Value | Method |
|---|---|---|
| **Cold start** (shell launch → sidecar pipe ready / first usable snapshot) | **~68 s** | `OpenUsage.log`: `sidecar starting` → `pipe listening` (e.g. 12:49:06 → 12:50:14 UTC); `smoke-sidecar.ps1` wall ~72 s |
| **RSS OpenUsageShell.exe** | **~92 MB** | `Get-Process WorkingSet64` after bootstrap |
| **RSS sidecar.exe** | **~101 MB** | Same |
| **RSS combined** | **~193 MB** | Shell + sidecar after first snapshot |

Dominant cold-start cost: sidecar `bootstrap()` refresh (Claude log scan + live APIs), consistent with Phase 3 heads-up.

---

## Spike-complete vs public beta blockers

### Spike-complete (research)

- Swift core + 6 providers in `spikes/windows-core/` with Windows adapters
- WPF tray/flyout + JSON named-pipe IPC
- Single-instance, launch-at-login toggle, toast stub, logging, sidecar supervision
- Dev scripts + unsigned zip packaging + draft CI workflows
- Research docs, feed schema, manual checklist

### Blocks public Windows beta

| Blocker | Notes |
|---|---|
| **Authenticode signing** | SmartScreen unknown publisher; no cert procured |
| **Production updater** | Stub only; need Velopack or equivalent + signature verify + atomic shell+sidecar update |
| **Production release workflow** | `release-windows.yml` not wired; shared-tag partial-failure runbook design only |
| **Merge to main tree** | macOS-gated `Package.swift` / target split not done |
| **UI parity** | No full dashboard, settings, customize, pinned tray metrics, global hotkey, accessibility gate |
| **Remaining providers** | Copilot, Devin, Antigravity not in spike shell |
| **Local HTTP API** | Port 6736 not implemented on Windows |
| **System integration gaps** | Explorer restart tray recovery, sleep/resume, full quota notification logic |
| **Owner decisions** | See below — several Phase 0 questions still open |
| **Beta soak / telemetry** | No crash-free-rate parity with macOS PostHog |

---

## Open questions — current recommendations

Copied from [windows-port-plan.md](windows-port-plan.md) with spike-informed recommendations:

| # | Question | Recommendation (2026-07-10) |
|---|---|---|
| 1 | Shell candidate A/B/C/D | **A** (WPF + Swift sidecar) — only candidate built and verified |
| 2 | OS floor: Win11-only vs Win10 LTSC | **Windows 11-only** for v1 (plan default; spike tested on Win11-class box) |
| 3 | Architectures: x64 vs x64+ARM64 | **x64 only** for first beta; ARM64 later |
| 4 | Packaged MSIX vs unpackaged installer | **Unpackaged** self-contained zip/installer for beta (matches spike); MSIX optional later |
| 5 | Pinned tray-metric design | **Defer** until owner/UI pass; not in spike |
| 6 | Credential write-back policy | **Read-only** third-party stores for beta; OpenUsage-owned files only for API keys |
| 7 | Antigravity on Windows | **Vault read + owner call** on process discovery vs cloud-only fallback |
| 8 | WSL scanning | **Post-v1** (confirmed) |
| 9 | System-proxy discovery | **Out of v1** — config-file proxy only (parity baseline) |
| 10 | Version strategy | **Same `0.7.x` shared tags** — owner approval required per AGENTS.md |

---

## Paths created (Phase 6)

| Path | Purpose |
|---|---|
| `docs/windows.md` | User/dev Windows draft doc |
| `docs/research/windows-manual-test-checklist.md` | Manual + smoke checklist |
| `docs/research/windows-phase6-findings.md` | This report |
| `spikes/windows-shell/scripts/phase6-smoke.ps1` | Headless smoke harness |
| `docs/README.md` | Windows research index (minimal edit) |

---

## Recommended next steps (owner)

1. Decide open questions 2–4, 5–7, 10 and procure signing (OV/EV/Azure Trusted Signing).
2. Plan production merge: `Package.swift` target split + port adapters from spike to `Sources/OpenUsage/`.
3. Choose updater (Velopack recommended in Phase 5) and wire `release-windows.yml` without touching macOS `release.yml` on partial failure.
4. Schedule UI parity + accessibility pass before any `-beta.N` Windows soak.
5. Port Copilot/Devin/Antigravity or ship Windows beta with a reduced provider set (explicit product call).

---

## Git status

All Phase 0–6 spike and doc changes remain **uncommitted** per port-plan instructions.
