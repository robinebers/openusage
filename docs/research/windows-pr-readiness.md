# Windows spike — PR readiness & path to product

Status: ready for a **research PR** after the cleanup pass below (Claude CLI consensus: **APPROVE WITH EDITS**, 2026-07-10).  
This is **not** a public Windows beta checklist.

Full consensus notes: [windows-spike-cleanup-consensus.md](windows-spike-cleanup-consensus.md).

---

## What this fork PR should contain

| Include | Exclude |
|---|---|
| `spikes/windows-core/`, `spikes/windows-shell/` | Changes under `Sources/OpenUsage/`, root `Package.swift` |
| `docs/windows.md`, `docs/research/windows-*` | Production `release.yml` / Sparkle / version bumps |
| `script/build_and_run.ps1`, `script/package_windows.ps1` | Signed installers, MSIX Widgets experiments |
| Spike CI: `windows-core-spike.yml`, `windows-shell-spike.yml` (path-filtered, `continue-on-error`) | Required status checks on `main` |

**Guardrail:** Do not bump the app version. Do not touch `0.6.x` / `tauri-legacy` release paths.

---

## Cleanup applied for PR credibility

From the consensus CLEANUP list:

- [x] Sidecar supervisor kills orphan `sidecar.exe` before launch / on stop
- [x] Remove “Phase 4 spike” user-facing copy
- [x] Refresh `spikes/windows-shell/README.md` + `PROTOCOL.md` for strip/flyout UX
- [x] Update `docs/windows.md` Differences + known limitations
- [x] `.gitignore` covers `**/bin/`, `**/obj/`, `spikes/**/.build/`
- [x] Spike CI workflows already path-scoped (verified)
- [x] Consensus artifact kept; scratch prompt removed

Polish included in the same pass:

- [x] Flyout “Refreshing…” banner during refresh
- [x] No-credential providers shown again (grey status), not hidden
- [x] 5-minute periodic refresh (macOS cadence)
- [x] Screenshots in `docs/windows.md` (`docs/research/images/`)
- [x] First-open flyout re-anchors after layout (no “grows downward” flash)
- [x] Strip click / double-click opens flyout
- [x] Toast app logo override (OpenUsage mark)

Deferred polish (fine after the research PR): `resetsAt` on IPC, cold-start cache, signing.

---

## Suggested git / `gh` flow (this machine)

`gh` is installed. Remote today: `origin` → `https://github.com/Cagatay342/openusage.git`.

```powershell
# 1) Branch off main (do not commit until you ask the agent / commit yourself)
git checkout -b research/windows-spike

# 2) Stage intentionally (never force-add bin/obj)
git add spikes/ docs/windows.md docs/research/ docs/README.md `
  script/build_and_run.ps1 script/package_windows.ps1 `
  .github/workflows/windows-core-spike.yml .github/workflows/windows-shell-spike.yml `
  .gitignore

git status   # review: no secrets, no dist/, no .build/

# 3) Commit (message sketch)
# research: Windows spike (Swift sidecar + WPF shell)
#
# Document Candidate A feasibility without touching the macOS production tree.

# 4) Push fork branch
git push -u origin HEAD

# 5) Open PR against upstream (add upstream remote if missing)
git remote add upstream https://github.com/robinebers/openusage.git   # once
git fetch upstream
gh pr create --repo robinebers/openusage --base main --head Cagatay342:research/windows-spike `
  --title "research: Windows spike (Swift sidecar + WPF shell)" `
  --body-file docs/research/windows-pr-body.md
```

When you want the agent to open the PR, say so explicitly after the commit exists on the fork.

---

## PR body template

Saved as [windows-pr-body.md](windows-pr-body.md) for `gh pr create --body-file`.

---

## Extra work for a real Windows *product* (post-research)

These are **not** required to open the research PR. They are the gap between “spike works on my PC” and “users can install OpenUsage on Windows.”

| Track | Work |
|---|---|
| **Architecture** | Extract shared `OpenUsageCore` from `Sources/` (or graduate the spike package); single provider/pricing implementation; drop long-term dual maintenance |
| **UI parity** | Customize, Settings, share cards, reset countdowns, pacing copy, accessibility (Narrator / High Contrast / keyboard) |
| **Providers** | Wire Copilot, Devin, Antigravity; API-key entry UX for OpenRouter/Z.ai |
| **System** | `TaskbarCreated` tray recovery; optional global hotkey; Mica/Acrylic; DPI matrix 100–300% |
| **Release** | Authenticode (OV/EV or Azure Trusted Signing); installer (Velopack or equivalent); atomic shell+sidecar update; SmartScreen reputation |
| **Ops** | Production update feed (schema stub exists); crash/minidump; PostHog HTTP seam |
| **Perf** | Cold start ≪ 60s (cached snapshot on boot, parallel bootstrap) |
| **Owner decisions** | Version line for Windows, support policy, whether floating strip is v1 or tray-only |

Phased detail: [windows-port-plan.md](windows-port-plan.md). Latest rollup: [windows-phase6-findings.md](windows-phase6-findings.md).

---

## Manual verify before you push

```powershell
.\script\build_and_run.ps1 verify
# Confirm: one OpenUsageShell + one sidecar; strip visible; flyout opens; Refresh works
Get-Process OpenUsageShell,sidecar
```

Optional: `.\script\package_windows.ps1` and launch from `dist/windows/OpenUsage/`.
