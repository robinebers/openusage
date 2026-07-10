# Windows Port Plan

Status: Final v3 (two consensus review rounds completed; round-2 verdict: APPROVE WITH MINOR EDITS, applied)
Owner: TBD
Last updated: 2026-07-10

This document is the phased plan for bringing OpenUsage to Windows at the same quality bar as the
macOS app. It is a planning/research document — nothing in here is committed work until the owner
signs off on scope, sequencing, and version strategy.

Revision notes:

- v2 (consensus round 1): corrected portability claims, measured LOC, moved
  packaging/signing/owner decisions into Phase 0, demoted the all-Swift-UI option from
  "recommendation" to one of four scored candidates, re-baselined the schedule.
- v3 (consensus round 2): system-proxy support marked as optional new scope (config-file proxy is
  the parity baseline), added access-control/composition-root and additional seam tasks
  (`IconSource`, scanner filesystem, app metadata/identity), relabeled the 9.3k figure as the
  Providers/Pricing subtotal, added an alternate Phase 1 path for candidate D, removed an
  unsupported symbol-limit claim, tightened Phase 2/5 acceptance criteria (API-key-only
  providers, account prerequisites, credential ACLs, updater signature/downgrade/interruption
  tests), and scheduled stale-doc corrections.

## Goals

- A native-feeling Windows tray app with parity for the product experience: providers, dashboard,
  customize, spend/pricing engine, notifications, auto-update, local read-only HTTP API.
- Same quality bar: fast, small, no jank, loud error reporting, testable architecture,
  accessibility (Narrator/UI Automation, High Contrast, keyboard-only).
- Minimize long-term drift between platforms — prefer one implementation of provider/pricing
  logic, but only if the measured total cost of ownership supports it (see Technology Decision).

## Non-Goals

- Linux support (out of scope, but decisions should not actively block it).
- Porting macOS-only affordances 1:1 (Liquid Glass, haptics, "Too Much Transparency" easter egg).
  Windows gets equivalent native affordances (Mica/Acrylic, Fluent) instead.
- WSL-hosted credential/log scanning in v1 (revisit post-v1; see Open Questions).
- Feature-for-feature pinned tray-metric strip: Windows tray icons are fixed-size, so pinned
  metrics need a Windows-specific design (decided in Phase 0, not assumed).

## Measured Baseline (2026-07)

| Metric | Value |
|---|---|
| Production Swift | 198 files, ~26.8k lines |
| `Providers/` + `Pricing/` subtotal | 62 files, ~9.3k lines |
| `Views/` (SwiftUI, spec for the Windows UI) | ~40 files, ~5.9k lines |
| Tests | 98 files, ~18.3k lines |

The 9.3k figure is a **folder subtotal, not a standalone core**: `Providers/` and `Pricing/`
depend transitively on models, HTTP/filesystem/process abstractions, logging, parsing, date
formatting, resource lookup, and stores. The actual reusable-core size is determined by the
Phase 1 portability inventory, not this table.

There is currently **one monolithic executable target** (`Package.swift`) with unconditional
macOS-only dependencies (KeyboardShortcuts, Sparkle, PostHog). No core library target exists yet;
the test target imports the executable. Any "compile the core on Windows" work requires target
extraction (or a temporary spike package) first.

## Current Portability Blockers

The core is **not** Foundation-only today. A Windows port is a dependency-graph redesign, not a
folder move. Known blockers and their intended resolution:

| Blocker | Where | Resolution |
|---|---|---|
| `os` / `OSAllocatedUnfairLock` | `Pricing/ModelPricing.swift`, `AppLog`, `LogFile`, `ProviderSnapshotCache` | Portable logging + locking (e.g. `Mutex`/`NSLock`, own log sink) — Phase 1 |
| `CryptoKit` | `Providers/Claude/ClaudeAuthStore.swift` | swift-crypto (cross-platform) — Phase 1 |
| `Network` (`NWListener`, proxy) | `Services/LocalUsageServer.swift`, `Services/ProxyConfig.swift` | Portable socket transport behind a protocol; explicit config-file proxy stays the parity baseline (see note below) — Phase 1 |
| Apple-specific `URLSession` proxy/server-trust APIs | `Services/HTTPClient.swift` | HTTP seam with per-platform transport (FoundationNetworking/curl or WinHTTP-backed) — Phase 1 |
| SwiftUI-adjacent `IconSource` used by portable models | Declared in `Support/ProviderIconShape.swift`; used by `Models/Provider.swift`, `Models/WidgetData.swift` | Move `IconSource` into a platform-neutral module — Phase 1 |
| Direct `FileManager` reads in log scanners | `Providers/IncrementalJSONLScanner.swift` | Injectable filesystem seam with Windows shared-read semantics — Phase 1/2 |
| `Bundle.main` app identity/version in telemetry | `Stores/TelemetryRecorder.swift`, `Stores/TelemetryStore.swift` | App-metadata/identity seam injected by each shell — Phase 1 |
| `Darwin` (`kill`, signals, `/usr/bin/env`, `pgrep`) | `Services/ProcessRunner.swift` | Per-platform process runner — Phase 1/2 |
| PostHog iOS SDK | `Services/Telemetry.swift` | Telemetry seam; Windows posts to PostHog HTTP API + crash capture (Phase 4) |
| SwiftUI imports in non-UI code | `Models/PlanWidget.swift`, `Stores/LayoutStore.swift` | Remove/replace with platform-neutral types — Phase 1 |
| AppKit in stores | `AppearanceSetting`, `DensitySetting`, `PopoverTransparencyStore` | Split platform-neutral state from AppKit application — Phase 1 |
| `ServiceManagement` | `Stores/LaunchAtLoginSetting.swift` | Autostart seam — Phase 4 |
| Hardcoded resource bundle name | `Support/ResourceBundle.swift` (`OpenUsage_OpenUsage.bundle`) | Bundle lookup that survives target split — Phase 1 |
| Concrete Sparkle/AppKit updater | `App/UpdaterController.swift` (not a protocol seam today) | Updater seam — Phase 5 |
| Notifications default-coupled | `Stores/WidgetDataStore.swift` defaults to `AppNotifications.shared` | Notification seam with injected default — Phase 1/4 |
| Process/port discovery via `ps`/`lsof` | `Services/LanguageServerDiscovery.swift` (Antigravity) | Toolhelp32/`GetExtendedTcpTable` equivalent, or cloud-fallback-only decision — Phase 2 |

Phase 1 begins by generating a **file-level portability inventory** (pure domain / portable after
refactor / macOS adapter / Windows adapter / UI-only / resources / tests) checked into
`docs/research/windows-portability-inventory.md`. Estimates are re-baselined from it.

## Credential Access Policy (corrected)

The macOS auth stores are **not** read-only: Claude, Codex, Cursor, and Grok all write refreshed
tokens back to their third-party sources (`ClaudeAuthStore`, `CodexAuthStore`, `CursorAuthStore`,
`GrokAuthStore`). The Windows port must make an explicit per-provider policy decision:

- May OpenUsage mutate third-party files/databases/Credential Manager entries on Windows
  (matching macOS behavior), or
- Do refreshed tokens go only into OpenUsage-owned storage (safer, but can diverge from what the
  provider's own tool sees)?

Default proposal: mirror macOS write-back behavior per provider, documented per provider in
Phase 2, with owner sign-off. "Never prompt the user for login" remains the invariant.

## Technology Decision

**Provisional hypothesis (to be validated, not assumed): reuse the Swift provider/pricing core;
choose the shell architecture from a scored Phase 0 bake-off.** Swift on Windows is an official,
credible platform (official x64/ARM64 toolchains; Arc shipped on it), which makes the shared-core
hypothesis testable — it does not by itself pick a UI technology.

Four candidates, scored in Phase 0 on: tooling maturity, debugging/crash symbolication, packaging
and runtime deployment, accessibility support, update story, and one-maintainer total cost of
ownership:

| # | Candidate | Reuse | Main risk |
|---|---|---|---|
| A | C#/WinUI 3 (or WPF) shell + Swift core **sidecar process** over private IPC | High | Two processes: lifecycle supervision, coordinated updates, IPC versioning |
| B | C# shell + Swift core compiled as a **DLL with C ABI** | High | ABI surface: memory ownership, callbacks, Swift concurrency across the boundary, symbol exports, mixed debugging |
| C | All-Swift: WinUI 3 via [swift-winrt](https://github.com/thebrowsercompany/swift-winrt) | Highest | 0.x vendor-maintained projection, may require toolchains newer than the latest release, mixed CMake/SPM build, slow debug rebuild loop, bus factor |
| D | Full C#/.NET rewrite (reimplement the provider/pricing logic — Providers/Pricing subtotal ~9.3k lines plus its transitive support code — in C#) | Lowest runtime reuse | Permanent dual implementation of provider logic; drift mitigated by shared golden fixtures |

Working preference for a one-maintainer project: **A**, because it keeps the Swift core buildable
with the official toolchain as a plain executable, avoids exposing Swift ABI, isolates crashes,
and keeps the shell on fully-supported Visual Studio/XAML/packaging/accessibility tooling. B and C
stay on the table only if their Phase 0 spikes are production-shaped and pass. D is a first-class
fallback, not a strawman: the reuse candidate is the ~9.3k-line Providers/Pricing subtotal (not
"35k"; final size comes from the portability inventory), much of the auth, process, filesystem,
proxy, and UI work is Windows-specific anyway, and drift is testable — the plan requires
**sanitized golden fixtures per provider** (raw API/log inputs → expected normalized
`ProviderSnapshot`) that can run against both a Swift and a C# implementation.

If **D wins** the bake-off, Phase 1 changes shape: instead of a Swift target split, Phase 1
becomes (a) defining the golden fixtures against the current Swift behavior, (b) standing up a
C# core project with the same capability seams, and (c) porting providers fixture-by-fixture.
Phases 2–6 apply unchanged; the "Architecture Overview" diagram below then describes the C# core
rather than a shared Swift core.

Rejected: Electron/Tauri shell — the project already migrated away from Tauri (`tauri-legacy`);
a web shell contradicts the native-quality bar.

### Interop contract (candidates A/B)

Not an afterthought — designed and spiked in Phase 0:

- **Do not reuse the public loopback HTTP API as the control plane.** It is read-only by design
  (`Services/LocalUsageAPI.swift`), currently serves `Access-Control-Allow-Origin: *`
  (`LocalUsageServer.swift`), and must never grow privileged endpoints (settings mutation, API-key
  management). It stays as the documented public read-only API on both platforms.
- Shell↔core channel: **named pipe restricted to the current user** (ACL'd), JSON (or
  MessagePack) DTOs, explicit version negotiation, state-snapshot + event-stream + command
  messages, cancellation, reconnect-after-core-restart semantics, defined threading rules.
- If B (C ABI) is chosen instead: opaque handles, caller/callee buffer-ownership rules, callback
  trampolines, and shutdown semantics are part of the spike, not deferred.

## Architecture Overview (Target)

```
                     shared Swift core (cross-platform)
  ┌────────────────────────────────────────────────────────────────┐
  │ Models (MetricLine, ProviderSnapshot, WidgetDescriptor)        │
  │ Providers (auth stores, usage clients, mappers, scanners)      │
  │ Pricing engine · portable stores (layout, settings, data)      │
  │ Portable services: HTTP seam, local API, process seam, logging │
  │ Small platform capability protocols (not one god-adapter)      │
  └────────────────────────────────────────────────────────────────┘
        │                                          │
  macOS adapters + AppKit shell            Windows adapters + shell
  (existing behavior preserved)            (credential vault, paths, tray,
                                            toasts, autostart, updater;
                                            shell per Phase 0 decision)
```

The platform seam extends what exists in `Services/SystemClients.swift` (`KeychainAccessing`,
`SQLiteAccessing`, `TextFileAccessing`, `EnvironmentReading`) and `Services/ProcessRunner.swift`
(`ProcessRunning`) — as **small per-capability protocols with clear dependency direction**, not a
single `PlatformAdapters` umbrella (service-locator risk). New seams needed: well-known
directories, notifications, autostart, single-instance, global hotkey, updater, telemetry/crash,
logging sink.

---

## Phase 0 — Architecture Bake-Off, Packaging Identity & Owner Decisions

Deliverable: the shell architecture chosen from production-shaped evidence; packaging model and
OS floor decided; signing procurement started. All recorded in this document.

Tasks:

1. Toolchains: official Swift Windows toolchain (x64; note ARM64 status) + VS/Windows App SDK.
   Record exact versions in `docs/research/windows-toolchain.md`.
2. **Core spike (real, not hardcoded):** on a disposable branch, extract a minimal core package
   (Models, Pricing, Grok provider — file-based auth, no keychain/SQLite — and
   `IncrementalJSONLScanner`), patching the known blockers (locking, logging, CryptoKit) just
   enough to compile. On Windows: run a real Grok auth→refresh→mapper pass against
   `%USERPROFILE%\.grok\auth.json`, load bundled pricing resources, persist a cache file, and run
   the existing Grok/pricing/scanner tests.
3. **Shell spikes, production-shaped.** Not every candidate is spiked — A always, B and C gated,
   D on paper (see below) — but every candidate that *is* spiked must demonstrate: tray icon with correct
   positioning (`Shell_NotifyIconGetRect`, GUID identity, `TaskbarCreated` re-registration), a
   key-focusable flyout (keyboard focus killed `MenuBarExtra` on macOS — verify the Windows twin
   early), a release build, packaged into a signed installer, installed and launched on a **clean
   Windows VM**, with measured installed size, RSS, and cold start, and a working
   crash-symbolication path.
   - A: C# shell + Swift sidecar exercising the real named-pipe protocol (snapshot, events,
     commands, reconnect).
   - B (only if A shows blocking problems or the owner wants it scored): C# shell + Swift DLL
     exercising the real C ABI (handles, buffers, callbacks, shutdown).
   - C (timeboxed): swift-winrt WinUI app from the core spike.
   - D is scored on paper (fixture-based drift control + .NET tooling maturity) unless A–C all
     fail, in which case a D spike runs.
4. **Packaging identity decision now, not Phase 5:** packaged (MSIX identity) vs unpackaged
   (classic installer + self-contained Windows App SDK) — this changes notifications, startup
   tasks, single-instance, updater options, and install permissions. Prototype the chosen model
   in the shell spike.
5. **Start code-signing procurement:** OV vs EV vs Azure Trusted Signing (SmartScreen reputation
   lead time is real); record certificate eligibility, CI signing access, timestamping, renewal
   owner.
6. CI: add a **non-required** `windows-latest` spike workflow building the core spike and running
   its tests. It becomes a required job only when green on `main` (never merge a permanently red
   required job).
7. **Owner decisions to lock in Phase 0:** OS floor (recommend Windows 11-only; Windows 10
   consumer support ended 2025-10), x64/ARM64 support, packaged vs unpackaged, shell candidate,
   pinned-tray-metric design direction (fixed-size icons: tooltip / compact single-metric icon /
   multiple icons), credential write-back policy, WSL out-of-v1 confirmation, and whether Windows
   adds **system-proxy discovery** (optional new scope — today's parity baseline is only the
   explicit `~/.openusage/config.json` proxy, default off, per `docs/proxy.md`; macOS has no
   system-proxy support either).

Exit criteria: core spike passes real Grok + pricing tests on Windows; exactly one shell
candidate selected with a written scorecard; packaging model proven on a clean VM; owner
decisions recorded. **Re-estimate the whole plan from these results.**

## Phase 1 — Core Portability (Target Split & Platform Seams)

Deliverable: a real `OpenUsageCore` library target that compiles on Windows with all portable
tests green in Windows CI; the macOS app rebuilt on top of it with no behavior change.

Tasks:

1. Generate the **file-level portability inventory** (`docs/research/windows-portability-inventory.md`)
   classifying every source/test file; re-baseline estimates from it.
2. Restructure `Package.swift` as a dependency graph: portable domain/orchestration →
   per-capability platform protocols → macOS adapter implementations → macOS shell composition
   root. Keep the shipped macOS product named `OpenUsage`. (Windows targets land in Phase 3.)
3. Resolve the Phase-1 blockers from the table above: portable logging/locking
   (`AppLog`/`LogFile`/`ModelPricing`), swift-crypto for Claude, HTTP/TLS/proxy seam (including
   the Antigravity loopback self-signed-TLS exception; explicit config-file proxy is the parity
   baseline — system-proxy discovery only if the owner approved it in Phase 0), local-server
   transport seam, remove SwiftUI from `Models`/`LayoutStore`, move `IconSource` out of
   `Support/ProviderIconShape.swift` into a platform-neutral module, split AppKit out of settings
   stores, fix the hardcoded resource-bundle lookup, split pricing JSON resources from UI assets,
   add the injectable filesystem seam for `IncrementalJSONLScanner`, and add an
   app-metadata/identity seam replacing `Bundle.main` reads in `TelemetryRecorder`/
   `TelemetryStore`.
   **Cross-target API design is explicit work, not a side effect:** today nothing in the proposed
   core is `public`/`package` (even `ProviderRuntime` is internal), and many provider
   initializers default to macOS concrete implementations (`SecurityKeychainAccessor`,
   `SQLiteCLIAccessor`, `URLSessionHTTPClient`). Phase 1 defines the `package`/`public` surface,
   removes platform-concrete default arguments from shared targets, and moves construction into
   per-platform composition roots.
4. `WellKnownPaths` seam replacing hardcoded `~/Library/Application Support/...`: audit every
   path in auth stores, `ModelPricingStore` cache, log file, settings storage; Windows maps to
   `%APPDATA%`/`%LOCALAPPDATA%`/`%USERPROFILE%`.
5. SQLite: replace `SQLiteCLIAccessor` (spawns `sqlite3`) with a linked-SQLite implementation
   behind `SQLiteAccessing` (`winsqlite3.dll` on Windows, `libsqlite3` on macOS), including
   **shared-read/WAL/busy-policy behavior spiked early** (prerequisite for Cursor/Devin in
   Phase 2, and removes subprocess latency on macOS too).
6. Credential seam: rename `KeychainAccessing` → `CredentialStoreAccessing`; macOS keeps
   `SecurityKeychainAccessor`; add `WindowsCredentialVaultAccessor` (`CredReadW`/
   `CredEnumerateW`). `LoginShellEnvironment` becomes a no-op on Windows (GUI apps inherit user
   env; `HKCU\Environment` as fallback).
7. Settings persistence: verify swift-corelibs-foundation `UserDefaults` on Windows or move
   behind a `SettingsStoring` seam (JSON file) keeping `SettingsMigrator` portable.
8. Test targets split into core / macOS-adapter / (later) Windows-adapter suites; create the
   **sanitized golden fixtures per provider** (inputs → expected `ProviderSnapshot`) as the
   cross-implementation drift guard.
9. macOS safety: every extraction step gated by macOS CI + full rebuild/relaunch verification
   (`script/build_and_run.sh verify`). A public macOS release from the split tree is an **owner
   decision** (AGENTS.md version guardrails), not a plan assumption — but the tree must be
   releasable at any point during Phase 1.
10. Update `docs/architecture.md` (and any affected docs) as the split lands — repo rules require
    docs to move with behavior, not in Phase 6. Also fix the already-stale statements found
    during review: AGENTS.md says the SwiftUI content is hosted in an `NSPopover` (it is a
    key-capable `NSPanel` — see `App/StatusItemController.swift`), and `docs/architecture.md`
    lists five providers while `App/AppContainer.swift` registers nine.

Exit criteria: Windows CI green for `OpenUsageCore` tests (job flips to required); macOS app
builds from the new graph with zero behavior change and passes its full suite.

## Phase 2 — Provider Platform Adapters (Research-First)

Deliverable: `hasLocalCredentials()` and `refresh()` verified on Windows for every v1 provider
classified as **native or API-key-only** (API-key providers like OpenRouter and Z.ai count —
they need no companion tool), each documented in `docs/providers/<name>.md`. Only providers
classified WSL-only or unavailable are excluded, with the exclusion documented.

Gate first: a **native-availability matrix** — for each provider, does the companion tool have a
native Windows install with a usable credential source? Classify: native / WSL-only / API-key-only
/ unavailable. WSL-only providers are explicitly out of v1 scope (documented per provider), so the
phase exit criterion is achievable.

Expected Windows credential sources (to verify against real installs, recording tool versions):

| Provider | Expected Windows source | Confidence |
|---|---|---|
| Claude | `%USERPROFILE%\.claude\.credentials.json`; some builds use Credential Manager (`Claude Code-credentials`) | High (file), Medium (vault) |
| Codex | `%CODEX_HOME%\auth.json` if set; else `%USERPROFILE%\.config\codex\auth.json`, then `%USERPROFILE%\.codex\auth.json` (mirrors the macOS fallback chain in `CodexAuthStore`) | High |
| Cursor | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` (same keys as macOS) | High |
| Copilot | `%APPDATA%\GitHub CLI\hosts.yml`; gh go-keyring → Credential Manager `gh:github.com`; `%LOCALAPPDATA%\github-copilot\apps.json` | Medium |
| Devin | `%APPDATA%\Devin\User\globalStorage\state.vscdb`; `credentials.toml` location unknown | Low — research |
| Grok | `%USERPROFILE%\.grok\auth.json` + `.grok\logs\unified.jsonl` | High (proven in Phase 0) |
| Antigravity | go-keyring → Credential Manager, service `gemini`, account `antigravity` (verify wincred target-name format) | Medium |
| OpenRouter | env vars + `%USERPROFILE%\.config\openusage\openrouter.json`; in-app key entry works regardless | High |
| Z.ai | env vars + `%USERPROFILE%\.config\openusage\zai.json`; in-app key entry works regardless | High |

Tasks:

1. Per-provider research pass on a real Windows machine; add a "Windows" section to each
   `docs/providers/*.md` (sources, tool versions, availability class, write-back policy).
2. Extend auth stores with Windows candidates behind `WellKnownPaths`/`CredentialStoreAccessing`;
   implement the per-provider **write-back policy** decided in Phase 0.
3. go-keyring unwrapping (`ProviderParse.unwrapGoKeyring`): verify wincred encoding matches the
   macOS base64 convention; branch per platform if not.
4. JSONL scanning (Claude/Codex/Grok): CRLF tolerance, path casing, and **shared-read file
   opening** (Windows locks files aggressively; scanners must not fail while the tool is
   writing). Antivirus interference noted and tested where feasible.
5. Cursor/Devin SQLite while the app is running: WAL + shared-memory sidecars, read-only open,
   busy/backoff policy, snapshot-copy fallback — tests land **here**, not Phase 6.
6. Antigravity process discovery: `LanguageServerDiscovery` uses `ps` + `lsof`; implement
   Toolhelp32Snapshot/`QueryFullProcessImageName` + `GetExtendedTcpTable` equivalents, or record
   an explicit owner decision to ship cloud-fallback-only on Windows.
7. Electron `safeStorage` blobs (Claude desktop) are DPAPI-encrypted on Windows —
   `CryptUnprotectData` may make them readable (unlike macOS). Investigate as stretch, not a
   parity blocker.
8. Windows fixture tests per provider (sample `state.vscdb`, `hosts.yml`, wincred mocks) plus the
   shared golden fixtures from Phase 1.
9. **Verification prerequisites up front:** list the accounts, paid tiers, and tool installs
   needed to verify each provider for real (e.g. active Claude/Codex/Cursor subscriptions,
   Copilot seat, Devin/Antigravity access), who provides them, and how evidence is captured with
   tokens redacted. Missing accounts are a schedule risk to surface at phase start, not at exit.
10. Credential hygiene: files OpenUsage writes on Windows (e.g. Antigravity's refreshed-token
    cache) get user-only ACLs — the NTFS equivalent of the `0600` semantics assumed on macOS.

Exit criteria: every in-scope (native or API-key-only) provider shows real data through the core
(headless harness or the chosen shell channel) on a Windows machine with the tool installed or
key configured; availability matrix + write-back policy documented per provider.

## Phase 3 — Windows UI Shell

Deliverable: the tray app renders the full dashboard in the chosen shell with the design language
adapted to Fluent.

Tasks:

1. Tray shell (Windows twin of `StatusItemController` + `MenuBarPanel`): NotifyIcon with GUID
   identity, high-DPI icon resources, positioning from `Shell_NotifyIconGetRect` + monitor work
   area (taskbar can be on any edge), re-registration on `TaskbarCreated` (Explorer restart),
   key-focusable borderless flyout with outside-click dismissal and height-morphing
   (`PanelHeightController` behavior), **right-click menu parity** (Settings, Quit — see
   `StatusItemController.swift`).
2. Pinned tray metrics: implement the Phase 0 design decision (fixed-size icon constraints).
3. Rebuild the view layer (the ~40 SwiftUI files under `Views/` are the spec): dashboard rows,
   provider cards, customize screens, settings, spend cards, sparklines, update banner, share
   cards. Share-card image rendering needs an early feasibility check (Win2D/XAML render target).
4. Appearance: light/dark via Windows theme, Mica/Acrylic as the transparency equivalent, density
   setting, Fluent-appropriate spacing while keeping OpenUsage's visual identity.
5. Keyboard: full keyboard navigation parity with `docs/dashboard.md`; global hotkey via
   `RegisterHotKey` (replaces macOS-only KeyboardShortcuts dependency).
6. Accessibility from the start, not as polish: UI Automation tree / Narrator, High Contrast,
   reduced motion, 100–300% per-monitor DPI, multi-monitor.

Exit criteria: side-by-side review vs. the macOS app; owner signs off on visual parity;
screenshots recorded per repo PR convention.

## Phase 4 — System Integration & Diagnostics

Deliverable: launch-at-login, notifications, single-instance, proxy, logging, telemetry, crash
reporting — all native and consistent with the Phase 0 packaging model.

Tasks:

1. Launch at login behind the autostart seam: `HKCU\...\Run` (unpackaged) or `StartupTask`
   (packaged) — per the Phase 0 decision.
2. Notifications: Windows toasts (packaging-model-appropriate API) driving the existing portable
   `QuotaNotificationEvaluator` + `PaceNotificationLogic`; notification activation opens the
   right screen.
3. Single instance: current macOS behavior is kernel `flock` (`SingleInstanceLock`) +
   `NSRunningApplication` activation (`SingleInstanceGuard`). Windows: named mutex +
   bring-existing-flyout-to-front. (There is no local-API port probe today — don't invent one.)
4. Local read-only HTTP API on `127.0.0.1:6736`: port the server transport (seam from Phase 1);
   verify no firewall prompt on loopback; tighten the `Access-Control-Allow-Origin: *` header
   decision consciously and identically on both platforms.
5. Proxy (`docs/proxy.md`): parity baseline is the explicit `~/.openusage/config.json`
   SOCKS5/HTTP(S) proxy (default off, no system-proxy pickup — same as macOS), through the
   Phase 1 seam; verify per-provider. System-proxy discovery only if the owner opted into that
   scope in Phase 0.
6. Logging: file log under `%LOCALAPPDATA%\OpenUsage\logs` with the same redaction rules
   (`docs/logging.md`).
7. Telemetry + **crash diagnostics**: PostHog via HTTP API (same schema, same opt-out); unhandled
   Swift (and .NET, if candidate A/B) exception capture; native minidump policy; PDB + Swift
   symbol retention/upload; a verified crash-report test from a signed release build.
8. Resilience: sleep/resume, session lock/unlock, network change, offline behavior.

Exit criteria: fresh-install first-run flow (`FirstRunSeeder`) works end to end on a clean VM
with notifications, autostart, and crash reporting verified.

## Phase 5 — Release Pipeline & Updates

Deliverable: signed installer + auto-update channel wired into CI, coexisting with the macOS
release flow, resilient to partial failure.

Tasks:

1. Installer + updater per the Phase 0 packaging decision (e.g. unpackaged: WiX/Inno + Velopack
   with Sparkle-equivalent semantics; packaged: MSIX + App Installer). Early-access channel
   mirrors `-beta.N` tags; feed lives on gh-pages next to `appcast.xml`.
2. Updater behavior parity with `docs/updates.md` (banner card, gentle reminders, manual check,
   early-access opt-in) behind an updater seam extracted from `App/UpdaterController.swift`
   (today a concrete Sparkle/AppKit class — the seam is new work).
3. Signing in CI with the certificate procured in Phase 0; **timestamped signatures on every
   executable, DLL, and installer**; SBOM/license inventory for new dependencies.
4. Release workflow: extend `release.yml` or add `release-windows.yml`; one tag drives both
   platforms. **Design for partial failure explicitly:** if macOS publishes and Windows signing
   fails, the release is repaired by re-running the Windows job for the same tag — never by
   reusing/bumping a version — and the macOS artifacts and legacy `latest.json` contract are
   never touched by the Windows job.
5. Update integrity: atomic update of shell + core (single installer unit); the updater
   **verifies Authenticode signatures on downloaded artifacts before applying** (signing alone
   proves nothing if the updater doesn't check); **downgrade rejection** (never apply a lower
   version from the feed); recovery from an interrupted/killed update and from locked running
   binaries; rollback story; verify auto-update from build N to N+1 on a clean VM, including a
   deliberately interrupted run.
6. Dev loop: `script/build_and_run.ps1` mirroring `build_and_run.sh` (kill, build, launch,
   verify); release-swift skill gains Windows guardrails.
7. Versioning: same `0.7.x+` line and shared tags — **owner approval required for any version
   decision** per AGENTS.md.

Exit criteria: tag → both platform artifacts published and auto-update verified end to end;
partial-failure runbook documented.

## Phase 6 — Quality Parity, Beta & Docs

Deliverable: public Windows beta on the early-access channel, then stable.

Tasks:

1. Test matrix: full portable suite + Windows-adapter suite in CI; manual checklist per provider
   on the supported OS floor (per Phase 0 decision — if Windows 11-only, there is no Windows 10
   testing).
2. Failure-mode audit: offline, expired tokens, missing tools, antivirus interference, Explorer
   restarts, multi-user machines, non-English locales/timezones/DST, non-ASCII user profiles.
3. Performance budgets: cold start, resident RSS ceiling, JSONL scan throughput on NTFS —
   measured against the Phase 0 baselines.
4. Accessibility gate: Narrator/UI Automation pass, High Contrast, keyboard-only operation,
   100–300% DPI — release blockers, not nice-to-haves.
5. Docs: "Windows" sections in every affected `docs/*.md`; new `docs/windows.md`; README platform
   matrix.
6. Beta soak on `-beta.N` builds; promote to stable when crash-free rate and provider success
   rates match macOS telemetry.

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Chosen shell architecture unshippable in production shape | High | Phase 0 spikes are production-shaped (signed installer, clean VM, crash symbolication) — not hello-world demos |
| Swift-on-Windows Foundation gaps (URLSession, Process, UserDefaults) | High | Phase 0 core spike + Phase 1 seams with regression tests; WinHTTP-backed client behind the HTTP seam as fallback |
| swift-winrt is 0.x and vendor-maintained (candidate C) | High | C is timeboxed and non-default; A is the working preference |
| Sidecar IPC complexity (candidate A) | Medium | Contract designed + spiked in Phase 0; reconnect semantics tested |
| Provider tools unavailable/undocumented natively on Windows | Medium | Phase 2 availability matrix gate; WSL-only providers explicitly out of v1; ship providers incrementally |
| Locked SQLite/WAL while Cursor/Devin run | Medium | Phase 1 linked-SQLite spike + Phase 2 shared-read/WAL tests |
| SmartScreen reputation for a new publisher | Medium | Signing procurement starts in Phase 0 (EV/Trusted Signing) |
| Core refactor destabilizes macOS app | High | Per-step macOS CI + rebuild/relaunch verification; releasable tree at all times; public release only on owner decision |
| Dual-implementation drift (if D, or partial C# in A/B) | Medium | Shared sanitized golden fixtures run against every implementation |
| One-maintainer schedule risk | High | Re-baseline after Phase 0 and after the Phase 1 inventory; 30–50% contingency reserve |

## Open Questions (owner decisions, due Phase 0)

1. Shell candidate (A/B/C/D) — from the scored bake-off.
2. OS floor: Windows 11-only (recommended) vs including Windows 10 LTSC.
3. Architectures: x64 only vs x64 + ARM64.
4. Packaged (MSIX identity) vs unpackaged (classic installer).
5. Pinned tray-metric design under fixed-size icon constraints.
6. Credential write-back policy per provider (mirror macOS vs OpenUsage-owned storage).
7. Antigravity on Windows: full process discovery vs cloud-fallback-only.
8. WSL scanning: confirmed post-v1.
9. System-proxy discovery on Windows: optional new scope (parity baseline is config-file proxy
   only) — in or out?
10. Version strategy: same `0.7.x` line, shared tags (owner approval per AGENTS.md).

## Sequencing & Effort (rough, one primary developer)

Raw phase estimates (before contingency):

| Phase | Estimate |
|---|---|
| 0 — Bake-off, packaging, decisions | 3–4 weeks |
| 1 — Core portability | 4–6 weeks |
| 2 — Provider adapters | 3–5 weeks |
| 3 — UI shell | 6–10 weeks |
| 4 — System integration & diagnostics | 3–4 weeks |
| 5 — Release pipeline | 2–3 weeks |
| 6 — Beta & polish | 3–4 weeks + beta soak |

Sum: 24–36 weeks. With a single developer there are **no real parallelization savings**
(interleaving is not parallelism), and a 30–50% uncertainty reserve is warranted until Phase 0
removes the architecture unknowns. Realistic envelope: **8–12 months to a stable Windows
release**; re-baseline after Phase 0 and again after the Phase 1 portability inventory. A second
developer shortens this meaningfully (core/providers vs. shell split cleanly after Phase 1).

## Consensus Review Record

This plan went through two rounds of independent review by Codex CLI (`codex exec`, read-only,
cross-checking claims against the codebase). Full review transcripts:

- Round 1 (against draft v1): `docs/research/windows-port-plan-reviews/round1-codex.md` — 23
  actionable edits, all incorporated into v2.
- Round 2 (against v2): `docs/research/windows-port-plan-reviews/round2-codex.md` — verdict
  **APPROVE WITH MINOR EDITS**; all 6 final edits incorporated into this v3.
