# Phase 5 Findings — Release Pipeline & Updates (Candidate A spike)

Status: **COMPLETE (local verify)** — dev loop script, self-contained zip packaging, update-check stub, and draft CI wired. Signing stubbed/documented only.
Date: 2026-07-10

Machine: `win32` developer box, Swift 6.3.3 `x86_64-unknown-windows-msvc`, .NET SDK 8.0, VS 2022 Build Tools 17.14.

---

## Executive summary

Phase 5 adds **packaging + release plumbing** for the Windows spike without a real code-signing certificate:

| Deliverable | Status |
|---|---|
| `script/build_and_run.ps1` (kill, build, launch, verify) | **Implemented** |
| `script/package_windows.ps1` (self-contained zip + sidecar + Swift DLLs) | **Implemented** |
| `UpdateChecker` stub (feed fetch + flyout banner + download link) | **Implemented** |
| `docs/research/windows-update-feed.schema.json` | **Added** |
| `.github/workflows/windows-shell-spike.yml` (draft, `continue-on-error`) | **Added** |
| Authenticode signing in CI | **Not wired** (documented below) |
| Velopack / WinSparkle production updater | **Deferred** (owner decision) |
| `release.yml` changes | **Not modified** (design documented below) |

---

## Dev loop: `script/build_and_run.ps1`

Mirrors `script/build_and_run.sh` for the spike tree:

```powershell
.\script\build_and_run.ps1          # build + launch
.\script\build_and_run.ps1 build    # build only
.\script\build_and_run.ps1 verify   # build + launch + exit 1 if not running
```

Steps:

1. Kill `OpenUsageShell` and `sidecar` processes
2. Set `SDKROOT` + Swift toolchain/runtime PATH
3. `swift build --product sidecar` inside `vcvars64.bat`
4. `dotnet build` the WPF shell (`C:\Program Files\dotnet\dotnet.exe` when present)
5. Launch `spikes\windows-shell\bin\Debug\...\OpenUsageShell.exe`
6. `verify` waits 2s and checks `Get-Process OpenUsageShell`

---

## Packaging: `script/package_windows.ps1`

Produces an **unsigned** self-contained distribution:

| Output | Path |
|---|---|
| Staged folder | `dist/windows/OpenUsage/` |
| Zip artifact | `dist/windows/OpenUsage-windows-x64.zip` |

Steps:

1. `swift build --product sidecar -c release`
2. `dotnet publish -c Release -r win-x64 --self-contained true` → `spikes/windows-shell/bin/publish/win-x64/`
3. Copy `sidecar.exe` next to `OpenUsageShell.exe`
4. Probe sidecar dependencies with `dumpbin /dependents`; copy Swift runtime DLLs from `%LOCALAPPDATA%\Programs\Swift\Runtimes\*\usr\bin\` (fallback: copy all runtime DLLs)
5. Zip the staged folder

**Layout (expected):**

```
OpenUsage/
  OpenUsageShell.exe
  sidecar.exe
  Foundation.dll, swiftCore.dll, … (Swift runtime DLLs)
  *.dll, *.json (self-contained .NET runtime)
```

Signing is intentionally omitted — SmartScreen will warn on first install until reputation builds.

---

## Update checker stub

**Code:** `spikes/windows-shell/UpdateChecker.cs`

| Behavior | Detail |
|---|---|
| Feed URL | `OPENUSAGE_UPDATE_FEED` env var, else `https://robinebers.github.io/openusage/windows-update.json` (placeholder, not live yet) |
| Local version | `AssemblyInformationalVersion` (`0.7.0-dev` in spike csproj) |
| Compare | Strip pre-release suffix, `System.Version` greater-than |
| UI | Non-blocking flyout banner: "Update available: *x.y.z* — Download" (opens URL in browser) |
| Install/replace | **Not implemented** — link-only stub |

**Feed schema:** `docs/research/windows-update-feed.schema.json` (`version`, `url`, `sha256`, `channel`, optional `notes` / `publishedAt`).

### Production updater choice (owner decision pending)

| Option | Pros | Cons |
|---|---|---|
| **Velopack** | Modern .NET delta updates, single-process feel | Two-binary (shell + sidecar) atomic update story needs custom hook |
| **WinSparkle** | Sparkle-parity semantics, EdDSA feeds | C++/Win32 dependency; WPF integration work |
| **Custom + gh-pages JSON** | Minimal deps (current stub) | No delta, no signature verify, no rollback |

Recommendation for Phase 5 production: **Velopack** for unpackaged self-contained layout if owner confirms unpackaged model from Phase 0; otherwise evaluate MSIX + App Installer. Either way, the updater must verify **Authenticode signatures** and `sha256` before applying (parity with `docs/updates.md`).

---

## CI: `.github/workflows/windows-shell-spike.yml`

- **Trigger:** `workflow_dispatch` + push to `main` when spike paths change
- **`continue-on-error: true`** — non-required until signing + green history
- **Steps:** Swift install, VS Build Tools, .NET 8, `swift test`, `script/package_windows.ps1`, upload `OpenUsage-windows-x64-unsigned` artifact
- **Signing:** commented in workflow — not wired

Existing `windows-core-spike.yml` remains for core-only builds.

---

## Future `release-windows.yml` design (NOT implemented)

Do **not** modify production `release.yml` until owner approves shared-tag Windows releases.

### Intended flow

1. **Same tag** as macOS (`v0.7.x` or `v0.7.x-beta.N`) triggers both platform jobs (either via `workflow_call` from `release.yml` or a sibling workflow listening on `release: published`).
2. **Windows job only:**
   - Run `script/package_windows.ps1` (or signed installer once WiX/Inno + Velopack land)
   - Authenticode-sign every EXE/DLL/installer with timestamp
   - Attach `OpenUsage-windows-x64.zip` (or `.exe` installer) to the **existing** GitHub Release for that tag
   - Publish `windows-update.json` to **gh-pages** next to `appcast.xml`
3. **macOS job untouched** — legacy `latest.json`, DMG, appcast, notarization stay in `release.yml`.

### Partial-failure rule

If macOS publishes successfully but Windows signing fails:

- **Do not** bump the version or cut a new tag
- **Do not** re-run or modify macOS artifacts / `latest.json`
- **Re-run** only the Windows job for the **same tag** after fixing signing
- Document the incident in release notes if the Windows asset arrives late

This mirrors the Phase 5 plan acceptance criteria and AGENTS.md version guardrails.

### Draft workflow

A `workflow_dispatch`-only draft can be added later as `.github/workflows/release-windows-draft.yml` once a signing secret (`AZURE_TRUSTED_SIGNING` or `CODESIGN_CERT_PFX`) is provisioned. Not added in this spike to avoid confusion with production `release.yml`.

---

## Signing gap

**No Authenticode certificate on this machine.** No enrollment or purchase was performed.

| Option | SmartScreen | Cost / lead time | CI fit |
|---|---|---|---|
| **Standard OV** | Reputation builds over weeks; initial warnings | ~$200–400/yr; 1–5 day validation | PFX in GitHub secret or HSM |
| **EV** | Faster reputation; hardware token | ~$400–700/yr; stricter identity proof | USB HSM or cloud HSM; harder in CI |
| **Azure Trusted Signing** | Microsoft-hosted; improving trust path | Azure subscription; org verification | GitHub Action `azure/trusted-signing-action`; no local PFX |

**Requirements for production:**

- Timestamp **every** signature (RFC 3161) so binaries remain valid after cert expiry
- Sign shell, sidecar, all bundled DLLs, and the outer installer/zip launcher
- Updater verifies Authenticode on downloaded artifacts **before** apply
- SBOM / license inventory for .NET + Swift runtime redistribution

Until signed, expect **Windows Defender SmartScreen** "Unknown publisher" warnings on the zip and executables.

---

## Build verification (local)

Verified 2026-07-10 on the Phase 5 Windows machine:

| Check | Result |
|---|---|
| `.\script\build_and_run.ps1 verify` | **PASS** — OpenUsageShell running after launch |
| `.\script\package_windows.ps1` | **PASS** — `dist/windows/OpenUsage-windows-x64.zip` (~85 MB) |
| Zip contents | `OpenUsageShell.exe`, `sidecar.exe`, 10 Swift runtime DLLs, self-contained .NET runtime |
| `swift test` (spikes/windows-core) | **287/287 pass** (3 skipped), 0 failures |

---

## Remaining Phase 5 / 6 gaps

| Gap | Notes |
|---|---|
| Velopack production updater | Stub is check+link only |
| Authenticode signing + timestamp | Cert procurement owner decision |
| `release-windows.yml` on shared tags | Design above; not wired |
| WiX/Inno installer | Zip-only spike; installer for production |
| Updater integrity tests | sha256 + signature verify + downgrade rejection + interrupted update |
| AUMID / Start Menu shortcut | Toast branding on unpackaged installs |
| Local HTTP API `127.0.0.1:6736` | Still deferred |
| `release-swift` skill Windows guardrails | Future chore |

---

## Paths created / modified

### Scripts

| File | Purpose |
|---|---|
| `script/build_and_run.ps1` | Dev loop |
| `script/package_windows.ps1` | Self-contained zip |

### Shell (`spikes/windows-shell/`)

| File | Purpose |
|---|---|
| `UpdateChecker.cs` | Feed fetch + version compare |
| `FlyoutWindow.xaml.cs` | Update banner with Download hyperlink |
| `App.xaml.cs` | Background update check on startup |
| `OpenUsageShell.csproj` | `0.7.0-dev` informational version |

### Docs / CI

| File | Purpose |
|---|---|
| `docs/research/windows-update-feed.schema.json` | Feed contract |
| `docs/research/windows-phase5-findings.md` | This document |
| `.github/workflows/windows-shell-spike.yml` | Draft CI |

---

## Heads-up

- **Swift runtime DLLs** must ship beside `sidecar.exe` on machines without a global Swift install; `package_windows.ps1` copies probe-discovered deps.
- **Self-contained .NET** inflates zip size (~60–80 MB) but avoids a separate .NET runtime install — appropriate for a tray app.
- **Update feed** 404 is expected until first Windows release publishes `windows-update.json` to gh-pages.
