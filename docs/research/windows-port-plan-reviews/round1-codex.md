# Round 1 verdict: Request changes

The plan has a useful phased structure and correctly identifies the nine providers and the custom tray-panel architecture. However, it overstates how much code is already portable, understates the target/interop work, and treats Swift/WinRT as the preferred answer before proving it is maintainable by one developer.

## 1. Factual errors and codebase mismatches

- **Replace the LOC and reuse claims with measured scope.** The repository currently has 198 Swift production files and roughly 26,839 physical source lines, not “~35k LOC of business logic.” `Providers/` + `Pricing/` + `Models/` total about 10,856 physical lines. There are 98 test files, not the “96-file test suite” cited in the risk table. Keep “~199 source files,” but remove the unsupported business-logic number and add a generated inventory.

- **Change “the portable core is Foundation-only” to a portability hypothesis.** Current counterexamples include:

  - `Sources/OpenUsage/Pricing/ModelPricing.swift:2,27` imports `os` and uses `OSAllocatedUnfairLock`.
  - `Sources/OpenUsage/Providers/Claude/ClaudeAuthStore.swift:1,413` imports `CryptoKit`.
  - `Sources/OpenUsage/Models/Provider.swift:7` and `WidgetData.swift:19` depend on `IconSource`, which is defined in the SwiftUI-heavy `Support/ProviderIconShape.swift`.
  - `Sources/OpenUsage/Services/LocalUsageServer.swift:2,16` and `ProxyConfig.swift:2,67` use Apple’s `Network` framework.
  - `Sources/OpenUsage/Services/ProcessRunner.swift:2,29-35,67-72` contains Darwin/POSIX paths, signals, and process-tree handling.
  - Several proposed shared stores import AppKit, SwiftUI, ServiceManagement, or directly call `AppNotifications`.

  Add an explicit source-to-target matrix rather than describing entire folders as portable.

- **Rewrite Phase 0 step 2 because `swift test` cannot currently build a subset.** `Package.swift:22-43` defines one executable target containing all of `Sources/OpenUsage`, and the only test target depends on that executable. Running `swift test` on Windows therefore attempts to compile AppKit, SwiftUI, Sparkle, KeyboardShortcuts, and PostHog code. Require either a temporary spike package or an initial minimal `OpenUsageCore` extraction before claiming existing Grok/pricing tests can run.

- **Delete the “5s subprocess cost” claim.** `SystemClients.swift:79-91` sets a five-second timeout; it does not impose a five-second cost on successful SQLite calls. The benefit of direct SQLite is lower process-launch overhead, better error handling, and controlled locking—not five seconds per query.

- **Stop calling the existing system wrappers complete platform seams.** They provide useful injection points, but platform implementations remain referenced as default arguments throughout providers. Examples include `SecurityKeychainAccessor`, `SQLiteCLIAccessor`, `URLSessionHTTPClient`, `ProcessEnvironmentReader`, and `LanguageServerDiscovery`. Likewise:

  - `LaunchAtLoginSetting.swift:1-25` directly imports and calls ServiceManagement.
  - `UpdaterController.swift:1-26` directly imports AppKit, Combine, and Sparkle.
  - `WidgetDataStore.swift:113-115` directly names `AppNotifications`.

  Change the document to require composition-root injection and removal of platform concrete defaults from shared targets.

- **Correct the local HTTP API description.** Its router is portable, but its transport is not: `LocalUsageServer.swift` uses `NWListener` and `NWConnection`. More importantly, `LocalUsageAPI.swift:22-47` only supports read-only `GET /v1/usage` routes. It cannot drive refresh, settings, provider enablement, API-key editing, or customization. Therefore it is insufficient as the C# shell boundary except for a display-only demo.

- **Remove “keep the read-only credential contract.”** Credential discovery is prompt-free, but the implementation is not read-only:

  - Claude and Codex persist rotated credentials.
  - Cursor writes refreshed access tokens into `state.vscdb`.
  - Antigravity writes an OpenUsage token cache.
  - OpenRouter and Z.ai expose in-app key save/delete operations.

  Replace this with “discovery must not prompt; adapters must support the existing read/write behavior, secure file permissions, atomic writes, and explicit failure reporting.”

- **Remove the claimed “local-API port probe” from single-instance behavior.** The application uses `SingleInstanceLock.swift` for `flock` and `SingleInstanceGuard.swift` for `NSRunningApplication` activation. There is no port probe. Port 6736 being occupied merely disables the API in `LocalUsageServer.swift:30-42`; it is not an identity test.

- **Remove “use system proxy” unless it is approved as new scope.** Current parity is an explicit `~/.openusage/config.json` proxy, default off, as documented in `docs/proxy.md:3-8` and implemented in `ProxyConfig.swift:32-40`. Reading WinHTTP/registry system settings would be a new feature, not a Windows mapping of existing behavior.

- **Correct the Phase 4 fresh-install notification criterion.** `NotificationSettingsStore.swift:4-6,35-39` defaults all notification triggers off and requests authorization only after opt-in. Replace “a fresh Windows user can … get notifications … with zero manual setup” with “a user can opt in and successfully receive and activate a notification.”

- **Clarify the tray terminology.** `NotifyIcon` is commonly the WinForms component name; the proposed raw path is `NOTIFYICONDATAW` plus `Shell_NotifyIconW`. Microsoft also recommends multiple DPI resources, `Shell_NotifyIconGetRect`, and native context-menu behavior—not a fixed 16×16/24×24 assumption. See [Microsoft’s notification-area guidance](https://learn.microsoft.com/en-us/windows/win32/shell/notification-area).

- **Add current-document inconsistencies to the prerequisite cleanup.** The plan correctly follows the actual custom `NSPanel` implementation in `StatusItemController.swift:15-25` and `docs/architecture.md:53-61`, while `AGENTS.md:26` still says `NSPopover`. `docs/architecture.md:13` also lists only five providers while `AppContainer.swift:58-67` registers nine. Move these documentation fixes into Phase 1/2 rather than waiting until Phase 6.

## 2. Missing phases, tasks, and risks

- **Add a target-boundary design task before splitting `Package.swift`.** Specify which files belong to domain models, provider runtime, portable services, Mac adapters, and Windows adapters. Account for Swift access control across targets: most declarations are currently `internal`, so the split requires `package`/`public` API decisions and test-target reorganization.

- **Add a resource-bundle migration task.** `ResourceBundle.swift:15-34` hardcodes `OpenUsage_OpenUsage.bundle`. Renaming/splitting targets changes SwiftPM’s generated resource-bundle name. Pricing snapshots and provider SVGs must be packaged and located on both platforms, including installed builds—not just `swift test`.

- **Add explicit replacements for Apple-only primitives.** The plan currently misses:

  - `OSAllocatedUnfairLock` in pricing and snapshot caching.
  - `os.Logger` in `AppLog` and `LogFile`.
  - `CryptoKit` in Claude auth. The supported cross-platform route is Apple’s `Crypto` package, not an unchanged `import CryptoKit`; see the [Swift Crypto documentation](https://github.com/apple/swift-crypto).
  - App/version metadata currently read through `Bundle.main`.
  - The loopback TLS exception used by Antigravity.

- **Add an Antigravity runtime adapter, not just credential research.** `LanguageServerDiscovery.swift:3-9,33-80` shells out to `/bin/ps` and `lsof`, parses POSIX command lines, and discovers listening ports. Antigravity also talks to a self-signed loopback TLS server. This is a separate Windows process-inspection/networking task and belongs in Phase 1/2.

- **Add a real file-access abstraction for scanners.** `IncrementalJSONLScanner.swift:23-40,128-138` bypasses `TextFileAccessing` and directly enumerates and reads files through `FileManager`. `WellKnownPaths` alone does not address Windows sharing flags, long paths, case-insensitive deduplication, antivirus races, or files changing between stat and read.

- **Add a versioned UI-control contract.** A Windows shell needs snapshots plus commands and events: refresh, provider enablement, layout mutation, API-key operations, settings, update state, errors, and notification activation. Define ownership, threading, cancellation, memory allocation, and schema versioning before UI implementation.

- **Add IPC security if the core is out of process.** Do not extend the existing public loopback API into a control API: it sends `Access-Control-Allow-Origin: *` in `LocalUsageServer.swift:128-131`. Use an ACL-restricted named pipe or an authenticated private channel. Keep the public read-only API separate.

- **Move packaging identity into the architecture gate.** Packaged versus unpackaged affects notifications, launch-at-login, runtime deployment, paths, updater behavior, and app identity. Microsoft explicitly treats packaging as an architectural choice, not a final release chore; see the [Windows packaging overview](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/packaging/).

- **Add Windows crash capture and symbolication.** Replacing PostHog’s SDK with HTTP event submission does not replace its crash/exception integration. Define handling for C# unhandled exceptions, WinRT failures, native/Swift crashes, minidumps, PDB/symbol publication, user opt-out, and redaction.

- **Add security tasks for credentials and updates.** Cover Credential Manager target enumeration, DPAPI user binding, config-file ACLs, updater signature verification, downgrade prevention, atomic replacement, and redaction tests. These are required by `AGENTS.md:71-73`’s loud-error/friendly-error rule.

- **Add accessibility and desktop-behavior acceptance tests.** Include Narrator/UI Automation, high contrast, reduced motion, text scaling, keyboard-only use, multiple taskbar positions, Explorer restart, auto-hide taskbar, mixed-DPI monitors, and overflow-tray placement. Screenshot comparison alone is insufficient.

- **Add an architecture support matrix.** Decide Windows 11 versus Windows 10 and x86_64 versus ARM64 in Phase 0. Official Swift toolchains support both x86_64 and ARM64 on Windows, but every dependency and installer still needs validation; see the [official Swift Windows installation page](https://www.swift.org/install/windows/).

- **Add provider-account and evidence requirements.** Nine real installations in three to four weeks assumes access to every tool, account tier, and credential mode. Require vendor/tool version, redacted discovery evidence, paid-account prerequisites, and a declared fallback when a provider has no supported Windows installation.

## 3. Technically questionable decisions

The document has not justified Swift/WinRT as the preferred UI choice for a solo maintainer.

| Option | Main advantage | Solo-maintainer cost | Round 1 position |
|---|---|---|---|
| Swift + Swift/WinRT UI | Lowest language duplication | Niche UI tooling, mixed CMake/SPM, XAML/WinRT expertise still required | Experimental candidate, not default |
| C# WinUI 3 shell + Swift core | Mature Windows UI/debugging while retaining provider logic | Two toolchains and a carefully designed ABI/IPC boundary | Leading hybrid candidate |
| Full C#/.NET implementation | One Windows-native toolchain and easiest integration | Duplicate provider/runtime logic | Credible comparator, not “only after everything fails” |

- **Replace the current recommendation with a hypothesis.** Swift itself is a legitimate Windows core technology, but that does not prove Swift/WinRT is the lowest-maintenance UI stack. The current [Swift/WinRT README](https://github.com/thebrowsercompany/swift-winrt) documents a mixed CMake/SPM workflow, slow rebuild caveats, and possible dependence on toolchains newer than the latest release. That is meaningful operational risk for one developer.

- **Remove the unsupported 64k-symbol explanation.** Upstream says C++ components are built with CMake and Swift components with SPM; the document should not attribute the whole build choice to an unmeasured export-limit problem. Require a reproduced failure or delete that rationale.

- **Stop describing option 1 as an “all-Swift binary.”** It will still ship Swift runtime libraries, Windows App SDK components, generated WinRT bindings, and likely C/C++ support code. Call it a “single-process Swift application” and measure installed size, DLL count, startup time, and RSS.

- **Make C#/WinUI 3 the default shell assumption.** It is the safer UI choice for Windows integration and debugging. Add a short WPF comparison as well: WPF is less Fluent by default but has more mature tray/window patterns and may be lower risk for a resident tray utility.

- **Keep Swift-core reuse conditional.** It is attractive only if Phase 0 proves an official stable toolchain, reproducible clean-machine builds, provider networking, resources, persistence, and a small bridge. If it requires a custom toolchain or large projection patches, the maintenance advantage disappears.

- **Elevate the full .NET rewrite to a real Phase 0 comparator.** The duplicated domain is closer to roughly 11–14k lines of provider/pricing/model/store logic than 35k. Drift can be constrained with shared JSON pricing assets, identical HTTP fixtures, golden mapper outputs, and cross-platform conformance tests. A rewrite may be cheaper over several years than maintaining Swift/WinRT plus CMake plus Windows-native adapters.

- **If using a Swift DLL, define a deliberately tiny C ABI.** Prefer opaque handles and versioned UTF-8 JSON snapshots/events, plus explicit allocation/free, error codes, callbacks, threading rules, and shutdown. Do not expose Swift structs, actors, or `MetricLine` object graphs directly.

- **If using two processes, choose named-pipe IPC rather than the public HTTP API.** The latter is read-only, optional when port 6736 is occupied, and intentionally CORS-accessible.

## 4. Sequencing and estimate problems

- **Move the OS floor, CPU architectures, packaging model, and pinned-tray UX into Phase 0.** They affect framework selection and acceptance criteria. Phase 6 cannot require Windows 10 testing while the support floor remains unresolved in Open Questions.

- **Do not add an intentionally red CI job.** Create an experimental non-required workflow or keep it on the spike branch. Merge gates should become required only when green; permanent red destroys signal.

- **Move logging, local-server transport, proxy transport, crypto, resources, and telemetry compilation into Phase 1.** They are dependencies of “the entire non-UI core compiles,” not Phase 4 polish.

- **Replace the mandatory “macOS no-op release” gate with owner-approved soak/release criteria.** Target splitting changes bundle/resource structure, so “byte-for-byte identical” is not realistic. Also, `AGENTS.md:17-21` prohibits initiating a version increase without explicit approval. Require green macOS tests, packaged-app smoke tests, and either a defined soak on `main` or an explicitly approved release.

- **Move the packaging choice ahead of launch-at-login and notifications.** MSIX versus classic installer changes the correct implementation. Deferring it to Phase 5 risks rewriting Phase 4.

- **Do not assume one shared tag can be published atomically.** One platform failing would leave a partial release. Add staged artifact creation, independent retry, publication gating, rollback, gh-pages deployment serialization, and explicit verification that `latest.json`, `appcast.xml`, pricing feeds, and Windows feeds all survive. Shared release cadence should remain an owner decision during beta.

- **Remove “partially parallel” from the one-developer estimate.** One developer cannot realize provider/UI parallelism without context-switching. Show dependencies and external lead time instead.

- **Rebaseline after Phase 0.** If the document needs a planning envelope now, a more defensible solo-developer range is:

  - Phase 0: 3–5 weeks
  - Phase 1: 6–10 weeks
  - Phase 2: 5–8 weeks
  - Phase 3: 8–16 weeks
  - Phase 4: 3–5 weeks
  - Phase 5: 3–6 weeks plus certificate/signing lead time
  - Phase 6: 4–8 weeks plus beta soak

  That implies roughly 8–14 months to stable, not 4–6 months, with the largest uncertainty being UI/interop choice and real-provider verification.

## 5. Concrete document improvements

1. **Replace the Technology Decision heading with “Technology Hypotheses and Phase 0 Decision Matrix.”** State: C# is the baseline Windows shell; Swift core reuse and Swift/WinRT are candidates to be proven; full .NET remains valid.

2. **Add a “Current Portability Inventory” table.** Give each source group a target owner and list blockers: SwiftUI/AppKit, `Network`, `os`, CryptoKit, ServiceManagement, Sparkle, PostHog, bundle resources, POSIX process APIs, or portable.

3. **Rewrite Phase 0 as three comparable vertical slices.** Each must perform a real Grok refresh, resolve bundled pricing, render the result, mutate one setting, receive a refresh event, build from a clean VM, and produce an installable artifact. Record build time, installer size, cold start, RSS, debugger quality, and required toolchain forks.

4. **Rewrite Phase 1 around target boundaries and dependency injection.** Include access-control migration, test-target split, resource-bundle migration, platform-free model types, logging/lock/crypto replacements, and removal of concrete Mac defaults from provider initializers.

5. **Split Phase 2 into credential adapters and provider runtime adapters.** The latter must cover Antigravity process discovery/TLS, scanner file semantics, SQLite WAL/locking, token persistence, and Windows-specific environment behavior.

6. **Add an explicit bridge/IPC specification before Phase 3.** The shell must have a versioned command/event contract and lifecycle rules, not just access to `MetricLine` values.

7. **Move deployment identity and updater selection before system integration.** Then implement launch-at-login, notifications, activation, and updates against the chosen packaged/unpackaged model.

8. **Replace screenshot-only UI sign-off with a Windows acceptance matrix.** Include focus, dismissal, tray restoration after Explorer restart, taskbar placement, DPI, accessibility, high contrast, keyboard navigation, and UI automation.

9. **Add release failure and rollback scenarios.** Test locked binaries, antivirus interference, failed delta/full updates, invalid signatures, interrupted installation, and preservation of all existing gh-pages artifacts.

10. **Update documentation continuously by phase.** `docs/architecture.md` must change when the package ceases to be one executable, and provider docs must change as each Windows credential/runtime path is verified—not only during final beta polish.

Method note: I treated SwiftPM target boundaries and the AppKit bridge as hard architectural boundaries rather than assuming folder names imply portability. No files were changed.