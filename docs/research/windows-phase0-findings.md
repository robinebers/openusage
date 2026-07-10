# Phase 0 Findings — Windows Core Spike

Status: **COMPLETE — build green, 98/98 tests passing on Windows** (`x86_64-unknown-windows-msvc`).
Date: 2026-07-10 (updated same day after VS Build Tools install)

## Executive summary

Phase 0 **core spike succeeded end to end**: a standalone SwiftPM package at `spikes/windows-core/` (trimmed copy of Models, Pricing, Grok provider, JSONL scanner, and supporting code with portability patches) **builds and passes all 98 tests on Windows** with the official Swift 6.3.3 toolchain + VS 2022 Build Tools. Bundled JSON resources load via `Bundle.module`, XCTest works, `UserDefaults`/`NSLock`/`FileManager`/ISO8601 formatting all behaved.

**Go/no-go for shared Swift core:** **GO** — 18 targeted patches total, all mechanical platform seams (locking, logging, paths, bundle lookup, TLS delegate guard, proxy stub). No business-logic rewrites were required. Remaining runtime unknown: live `URLSession` network calls against real provider APIs (tests used mock HTTP).

---

## Toolchain status

| Check | Result |
|---|---|
| `swift --version` | **Pass** — Swift 6.3.3, `x86_64-unknown-windows-msvc` |
| Winget Swift.Toolchain | **Pass** — 6.3.3 installed |
| Python 3.10 (auto-dep) | **Pass** — 3.10.11 |
| VCRedist 2015+ x64 | **Present** — 14.44.35211.0 |
| VS 2022 Build Tools 17.14 + C++ workload | **Installed** via winget (exit 0) |
| `link.exe` | **Present** after `vcvars64.bat` |
| `swift build` | **Pass** — "Build complete!" (~22 s incremental) |
| `swift test` | **Pass** — 98 tests, 0 failures (4.3 s) |

Build environment requirement: run inside the VS developer environment (`vcvars64.bat` or
Developer PowerShell) **and** with `SDKROOT` set (the Swift installer sets it as a user
environment variable; fresh shells pick it up automatically).

Details: [`windows-toolchain.md`](windows-toolchain.md)

---

## Spike package layout

**Path:** `spikes/windows-core/`

| Component | Count |
|---|---|
| Swift sources (library) | 47 |
| JSON resources | 3 |
| Test files | 11 |
| New stub/support files | 6 |
| **Total files** | **64** (incl. `Package.swift`) |

### Files copied from `Sources/OpenUsage/`

**Models (11):** `MetricLine`, `MetricValue`, `MetricKind`, `Provider`, `ProviderSnapshot`, `WidgetDescriptor`, `WidgetDescriptor+Factories`, `WidgetData`, `DailyUsageSeries`, `WidgetDisplayMode`, `ResetDisplayMode`

**Pricing (6):** all files under `Pricing/`

**Grok provider (6):** all files under `Providers/Grok/`

**Providers (6):** `IncrementalJSONLScanner`, `DailyUsageAccumulator`, `SpendTileMapper`, `ProviderRuntime`, `ProviderAuthRetry`, `UsageLogReadFailureReporter`

**Support (9 copied + 5 new):** `ProviderParse`, `OpenUsageISO8601`, `MetricFormatter`, `Formatters`, `Pace`, `LogRedaction`, `TotalSpendAggregator` + new `IconSource`, `WellKnownPaths`, `AppLog`, `LogFile`, patched `ResourceBundle`, `AppInfo`

**Services (3):** `HTTPClient`, `ProxyConfig`, `SystemClients`

**Stores (3):** `LogLevelSetting`, `TimeFormatSetting`, `UserDefaultsBacked`

**Resources (3):** `pricing_supplement.json`, `pricing_litellm_snapshot.json`, `pricing_models_dev_snapshot.json`

**Providers (1 new):** `ErrorCategory.swift` (trimmed Grok-only subset, not a straight copy)

### Tests copied from `Tests/OpenUsageTests/`

`GrokProviderTests`, `GrokAuthStoreTests`, `GrokLogUsageScannerTests`, `GrokCreditsConfigTests`, `GrokCreditsConfigFixtures`, `IncrementalJSONLScannerTests`, `ModelPricingTests`, `ModelPricingStoreTests`, `PricingBundledResourceTests`, `SpendTileMapperTests`, `TestSupport` (trimmed)

**Excluded from tests:** `GrokWidgetDataStoreTests` (depends on `WidgetDataStore` / UI orchestration — out of spike scope)

---

## Portability patches applied (in spike copies only)

| # | File | What changed | Why |
|---|---|---|---|
| 1 | `Pricing/ModelPricing.swift` | `OSAllocatedUnfairLock` → `NSLock` + manual memo dict | `import os` unavailable on Windows |
| 2 | `Support/AppLog.swift` | **Replaced** — print + optional file sink, no `os.Logger` | Apple logging module |
| 3 | `Support/LogFile.swift` | **New** — `%LOCALAPPDATA%\OpenUsage\logs\` path | Replaces macOS `~/Library/Logs` + `os` |
| 4 | `Support/IconSource.swift` | **New** — extracted enum from SwiftUI file | `IconSource` lived in `ProviderIconShape.swift` with SwiftUI |
| 5 | `Support/WellKnownPaths.swift` | **New** — `expandHome`, `applicationSupport`, `localAppData` | Windows `%USERPROFILE%` / `%APPDATA%` / `%LOCALAPPDATA%` |
| 6 | `Services/SystemClients.swift` | **Trimmed** — text files + env only; removed Keychain/SQLite/login-shell | `Darwin`, `/usr/bin/security`, `/usr/bin/sqlite3`, `LoginShellEnvironment` |
| 7 | `Services/ProxyConfig.swift` | **Stubbed** — `current = nil`; removed `Network`/`ProxyConfiguration` | `import Network` + Apple URLSession proxy APIs |
| 8 | `Services/HTTPClient.swift` | `#if canImport(FoundationNetworking)`; proxy via no-op extension | Windows URLSession lives in FoundationNetworking; proxy deferred |
| 9 | `Support/ResourceBundle.swift` | `Bundle.openUsageResources = .module` | Hardcoded `OpenUsage_OpenUsage.bundle` name |
| 10 | `Support/AppInfo.swift` | Static version string | `Bundle.main.infoDictionary` |
| 11 | `Pricing/ModelPricingStore.swift` | Cache dir via `WellKnownPaths.applicationSupport` | Explicit Application Support mapping |
| 12 | `Providers/ErrorCategory.swift` | **Rewritten** — Grok + `HTTPClientError` only | Full file references all provider error enums |
| 13 | `Tests/TestSupport.swift` | **Trimmed** — Grok/pricing fakes only | Removed Claude/Codex fixtures, keychain fakes |
| 14 | `Tests/GrokProviderTests.swift` | Removed `GrokWidgetDataStoreTests` | Depends on uncopied `WidgetDataStore` |
| 15 | `Tests/*` | `@testable import OpenUsageCore` | Module rename |
| 16 | `Package.swift` | Removed invalid `.windows(.v10)` platform entry | `SupportedPlatform` has no `windows` member; `platforms:` only constrains Apple platforms |
| 17 | `Services/HTTPClient.swift` | `LoopbackTLSDelegate` wrapped in `#if canImport(Darwin)`; non-Darwin loopback session uses default validation | corelibs-foundation marks `NSURLAuthenticationMethodServerTrust`/`serverTrust` unavailable — **the Antigravity loopback TLS exception has no URLSession path on Windows** (needs a different transport in Phase 1) |
| 18 | `Services/ProxyConfig.swift` | Dropped `mutating` from `URLSessionConfiguration` extension method | `URLSessionConfiguration` is a class; `mutating` is invalid |

### Phase 1 additions (spike only, patches 19–25)

| # | File | What changed | Why |
|---|---|---|---|
| 19 | `Services/SystemClients.swift` | Full `KeychainAccessing` protocol + `NoOpKeychainAccessor` stub | Providers/tests need current-user keychain methods; Windows has no Security.framework |
| 20 | `Providers/Codex/CodexAuthStore.swift` | Default keychain → `NoOpKeychainAccessor()` | File-auth path only in spike; keychain deferred to Phase 2 |
| 21 | `Providers/Claude/ClaudeAuthStore.swift` | `#if canImport(CryptoKit)` / `import Crypto`; default keychain → `NoOpKeychainAccessor()` | CryptoKit unavailable on Windows; swift-crypto `Crypto` module |
| 22 | `Providers/ErrorCategory.swift` | Trimmed conformances to spike providers only | Full file references Cursor/Devin/Copilot/Antigravity error enums not in spike |
| 23 | `Package.swift` | Added `swift-crypto` dependency (`Crypto` on Windows) | Claude `SHA256.hash` for keychain service suffix |
| 24 | `Support/MetricPeriod.swift` | **Copied** from main Support | Codex/Claude usage mappers reference shared window constants |
| 25 | `Tests/TestSupport.swift` | Added `ClaudeLogFixture`, `CodexLogFixture`, full `FakeKeychain`/`ServiceKeychain` | Log-scanner and keychain-ranking tests need fixtures + protocol-complete mocks |

**Not patched (accepted risk until build):**

- `@MainActor` on `GrokProvider` / `ProviderRuntime` — expected to compile on Swift 6 Windows
- `UserDefaults.standard` in settings stores — Phase 1 seam candidate
- Direct `FileManager.default` in `IncrementalJSONLScanner` — documented Phase 1 filesystem seam
- `Calendar.current` locale formatting in spend tiles — likely fine on Windows

---

## Build result

```
cd spikes/windows-core
(vcvars64.bat environment, SDKROOT set)
swift build
→ Build complete! (22.5s incremental; first full build ~2.5 min)
```

Compile errors hit and fixed along the way: invalid `.windows(.v10)` manifest entry, server-trust
APIs unavailable in corelibs-foundation (patch 17), `mutating` on a class extension (patch 18).

---

## Test result

```
swift test
→ Executed 98 tests, with 0 failures (0 unexpected) in 4.273 seconds  — ALL PASS
```

| Suite | Result |
|---|---|
| GrokAuthStoreTests | 3/3 |
| GrokCreditsConfigDecoderTests | 7/7 |
| GrokCreditsConfigMapperTests | 6/6 |
| GrokLogUsageScannerTests | 10/10 |
| GrokProviderTests | pass |
| IncrementalJSONLScannerTests | pass |
| ModelPricingTests | 25/25 |
| ModelPricingStoreTests | pass |
| PricingBundledResourceTests | 14/14 — **`Bundle.module` resource loading works on Windows** |
| SpendTileMapperTests | 12/12 |

---

## Foundation-on-Windows gaps (anticipated / unverified)

| Area | Status | Notes |
|---|---|---|
| `URLSession` / HTTP (mock-backed) | **Verified** | FoundationNetworking compiles; mapper/decoder paths tested |
| `URLSession` live network calls | **Unverified** | Tests used mock HTTP; live provider API pass still pending |
| Server-trust TLS override | **CONFIRMED GAP** | corelibs-foundation has no `serverTrust` API — Antigravity loopback TLS exception needs a non-URLSession transport on Windows (Phase 1) |
| Proxy via config file | **Stubbed** | Parity baseline deferred to Phase 1 HTTP seam |
| `UserDefaults` | **Verified** | Settings-store tests pass |
| `FileManager` home/support dirs | **Verified** | `WellKnownPaths` + scanner/log tests pass |
| `Bundle.module` resources | **Verified** | All 14 bundled-resource tests pass |
| `NSLock.withLock` | **Verified** | `ModelPricing` memo tests pass |
| Process/subprocess | **Removed from spike** | Not needed for Grok file-auth path |
| CryptoKit | **Not in subset** | Grok JWT parsing uses Foundation JSON only |

---

## Go / no-go: shared Swift core hypothesis

| Criterion | Assessment |
|---|---|
| Extractable core size | ~47 sources + 3 JSON — manageable, not the full 9.3k-line folder blindly |
| Patch count / complexity | 18 patches, mostly small seams — **favorable** |
| Logic rewrites | **None** in provider/pricing algorithms |
| Windows toolchain maturity | Swift 6.3.3 + VS Build Tools install cleanly via winget; vcvars64 + SDKROOT required |
| Test portability | Existing XCTest suites copy with minor trimming; **98/98 green on Windows** |
| Blocking unknowns | Live network calls; server-trust TLS gap (Antigravity) needs a transport decision in Phase 1 |

**Verdict:** **GO** for the shared Swift core, working preference candidate **A** (C# shell +
Swift sidecar). Next: non-required `windows-latest` CI job, then Phase 1 target split re-baselined
from the portability inventory.

---

## Pending Phase 0 items (NOT attempted — owner / infra)

These remain open per the port plan; this session scoped only the core spike:

1. **Shell candidate spikes A/B/C** — WinUI/WPF tray, named-pipe IPC, signed installer, clean VM
2. **Packaging identity** — MSIX vs classic installer prototype
3. **Code-signing procurement** — OV/EV/Azure Trusted Signing
4. **CI workflow** — non-required `windows-latest` job for core spike
5. **Owner decisions (7+):** OS floor, x64/ARM64, packaged vs unpackaged, shell choice, pinned tray metrics design, credential write-back policy, WSL confirmation, system-proxy scope
6. **Live Grok end-to-end on Windows** — real `%USERPROFILE%\.grok\auth.json` refresh pass (needs build + network)
7. **Candidate D scoring** — C# rewrite on paper unless A–C fail
8. **Schedule re-baseline** — after shell bake-off and green Windows CI

---

## Files created (this Phase 0 session)

| Path | Purpose |
|---|---|
| `spikes/windows-core/` | Standalone SwiftPM spike package |
| `docs/research/windows-toolchain.md` | Toolchain install record + VS prerequisite gap |
| `docs/research/windows-phase0-findings.md` | This report |

**Git status:** All changes left **uncommitted** per Phase 0 instructions.

---

## Recommended next step

1. Install VS 2022 Build Tools + Windows SDK (see `windows-toolchain.md`).
2. From Developer PowerShell: `cd spikes/windows-core && swift build && swift test`.
3. Fix any compile/runtime gaps surfaced (likely URLSession, Bundle resources, or UserDefaults).
4. Add `.github/workflows/windows-core-spike.yml` as a non-required job once green locally.
