# Phase 1 Report — Windows Core Spike Expansion

Status: **COMPLETE on Windows machine** — build green, **274/274 tests passing** (3 skipped), 0 failures.
Date: 2026-07-10

Scope executed on Windows (no macOS SDK): Task A inventory, Task B spike expansion (Codex + Claude + OpenRouter/ZAI), Task C CI workflow, this report. The real `Package.swift` target split (Task B of plan Phase 1 on macOS) was **not attempted** — requires macOS CI.

---

## Spike build/test results

| Metric | Phase 0 | Phase 1 |
|---|---|---|
| Library Swift sources | 47 | **71** |
| Test files | 11 | **18** |
| Providers in spike | Grok | **Grok, Codex, Claude, OpenRouter, Z.ai** |
| Tests executed | 98 | **274** (3 skipped) |
| Failures | 0 | **0** |
| Build time (incremental) | ~22 s | ~2 min (first build with swift-crypto); incremental ~2 min |
| Test time | 4.3 s | **3.9 s** |

Invocation (unchanged from `windows-toolchain.md`):

```powershell
$env:SDKROOT = [Environment]::GetEnvironmentVariable("SDKROOT","User")
cd spikes\windows-core
cmd /s /c "`"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat`" && swift build && swift test"
```

Toolchain: Swift **6.3.3** (`x86_64-unknown-windows-msvc`), VS 2022 Build Tools 17.14, swift-crypto **3.15.1**.

---

## Task A — Portability inventory

Deliverable: [`windows-portability-inventory.md`](windows-portability-inventory.md)

### Source totals (`Sources/OpenUsage/`, 198 files)

| Category | Count | Target |
|---|---|---|
| PORTABLE-AS-IS | 96 | `OpenUsageCore` |
| PORTABLE-AFTER-SEAM | 27 | `OpenUsageCore` (after seams) |
| MACOS-ADAPTER | 22 | `OpenUsageMacAdapters` |
| WINDOWS-ADAPTER-NEEDED | 4 | `OpenUsageWindowsAdapters` |
| UI-SHELL | 49 | `OpenUsageMacApp` (+ Windows shell in Phase 3) |

### Test totals (`Tests/OpenUsageTests/`, 98 files)

| Classification | Count |
|---|---|
| core-portable | 61 |
| macos-only | 31 |
| needs-windows-fixture | 6 |

Key finding: **123/198 source files** (62%) are portable-as-is or portable-after-seam — the shared core hypothesis holds. The 49 UI-SHELL files are the Windows respec, not a port.

---

## Task B — Spike additions

### Providers added

| Provider | Files copied | Tests ported |
|---|---|---|
| **Codex** | `CodexAuthStore`, `CodexLogUsageScanner`, `CodexProvider`, `CodexUsageClient`, `CodexUsageMapper` | `CodexProviderTests`, `CodexLogUsageScannerTests` (+ embedded mapper/client/auth suites) |
| **Claude** | All 5 Claude provider files | `ClaudeProviderTests`, `ClaudeLogUsageScannerTests` (+ embedded mapper/auth suites) |
| **OpenRouter** | 4 files + shared `UserAPIKeyStore`, `APIKeyManagement`, `ProviderUsageErrorText` | `OpenRouterProviderTests` |
| **Z.ai** | 4 files | `ZAIProviderTests`, `ZAILiveResponseMappingTests` |

### Shared support added

- `Support/MetricPeriod.swift` — window constants for Codex/Claude mappers
- Full `Providers/ErrorCategory.swift` (trimmed to spike providers)
- `swift-crypto` package dependency for Claude `SHA256`

### Patches (Phase 0 #19–25)

See [`windows-phase0-findings.md`](windows-phase0-findings.md) patch table rows 19–25.

Notable new Foundation-on-Windows finding:

- **Protocol witness dispatch:** `KeychainAccessing.readGenericPasswordForCurrentUser` must be a **protocol requirement**, not only a protocol-extension default, or test doubles (`ServiceKeychain`) silently fall through to `readGenericPassword` when called through an existential. Fixed in spike `SystemClients.swift` (patch #19).

---

## Task C — CI workflow

Created [`.github/workflows/windows-core-spike.yml`](../../.github/workflows/windows-core-spike.yml):

- Triggers: `workflow_dispatch` + push to `main` when spike paths change
- Runner: `windows-latest`
- Installs Swift via winget + ensures VS C++ tools; builds/tests inside `vcvars64.bat`
- **`continue-on-error: true`** — explicitly non-required spike job
- Comment header marks it as spike-only, not the shipped app

Note: `swift-actions/setup-swift` does not reliably support Windows; winget path mirrors local Phase 0 setup.

---

## Remaining for "real" Phase 1 (macOS CI required)

These steps from the port plan **cannot execute on this Windows-only machine**:

1. **Target split of root `Package.swift`** into:

```
OpenUsageCore          ← PORTABLE-AS-IS + PORTABLE-AFTER-SEAM (after seams land)
OpenUsageMacAdapters   ← MACOS-ADAPTER (SystemClients, LoginShellEnvironment, Telemetry SDK, …)
OpenUsageMacApp        ← UI-SHELL + AppContainer composition root
OpenUsageWindowsAdapters ← WINDOWS-ADAPTER-NEEDED (ProcessRunner, SingleInstanceLock, LocalUsageServer, LanguageServerDiscovery) + Phase 2 credential vault
```

2. **Apply Phase 0/1 seams to the real tree** (not spike copies): logging, IconSource extraction, Bundle.main → app-metadata, WidgetDataStore notification injection, linked SQLite, CredentialStoreAccessing rename, public/package API surface.

3. **Split test targets:** `OpenUsageCoreTests` (61 core-portable + spike-proven provider tests), `OpenUsageMacAdapterTests`, later `OpenUsageWindowsAdapterTests`.

4. **macOS verification gate:** every extraction step via `script/build_and_run.sh verify` + full macOS test suite.

5. **Flip Windows CI to required** once the real `OpenUsageCore` target (not spike) is green on `main`.

---

## Files created/modified (Phase 1 session)

### Created

| Path | Purpose |
|---|---|
| `docs/research/windows-portability-inventory.md` | Task A file-level inventory |
| `docs/research/windows-phase1-report.md` | This report |
| `.github/workflows/windows-core-spike.yml` | Non-required Windows spike CI |

### Modified (spike + docs only — no `Sources/OpenUsage/` or root `Package.swift`)

| Path | Change |
|---|---|
| `spikes/windows-core/Package.swift` | swift-crypto dependency |
| `spikes/windows-core/Package.resolved` | Lockfile (swift-crypto 3.15.1) |
| `spikes/windows-core/Sources/OpenUsageCore/**` | +24 provider/support files, SystemClients/ErrorCategory patches |
| `spikes/windows-core/Tests/OpenUsageCoreTests/**` | +7 test files, TestSupport fixtures |
| `docs/research/windows-phase0-findings.md` | Patches #19–25 appended |

---

## Blockers / open items

| Item | Status |
|---|---|
| Live network calls against real Codex/Claude/OpenRouter/Z.ai APIs on Windows | Unverified (tests use mock HTTP) |
| Windows CI workflow on GitHub | Created locally; **not pushed** (no git commit per instructions) |
| Real Package.swift target split | Blocked on macOS machine/CI |
| Cursor/Devin/Copilot/Antigravity providers in spike | Deferred — need SQLite/credential adapters (Phase 2) |
| Keychain parity for Codex/Claude on Windows | Stubbed (`NoOpKeychainAccessor`); file-auth paths work |

---

## Recommended next steps

1. macOS agent: land target split using inventory category → target mapping above; gate each step with macOS CI.
2. Push branch + verify `windows-core-spike.yml` on GitHub Actions.
3. Phase 2: Windows credential vault (`CredReadW`/`CredWriteW`) behind `CredentialStoreAccessing`; verify Codex/Claude keychain paths on real Windows installs.
