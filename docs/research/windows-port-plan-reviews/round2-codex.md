# Final verdict

## 1. Round-1 verification

Most round-1 issues were fixed correctly:

- The measured baseline is exact: 198 production Swift files/26,839 lines, 62 provider/pricing files/9,286 lines, 40 view files/5,863 lines, and 98 test files/18,348 lines.
- The monolithic target and Windows test limitation are now accurately described. [Package.swift](/C:/Users/yildi/Repos/openusage/Package.swift:22) still has one executable target, unconditional macOS dependencies, and a test target importing that executable.
- The portability blockers now cover logging/locking, CryptoKit, Network, Darwin, AppKit/SwiftUI stores, resource lookup, Sparkle, notifications, and Antigravity discovery.
- The local HTTP API is correctly kept read-only and separate from the privileged shell/core channel. [LocalUsageAPI.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Services/LocalUsageAPI.swift:22) only exposes `GET /v1/usage`; the named-pipe proposal is appropriate.
- Credential behavior is now correct: Claude, Codex, Cursor, and Grok can persist rotated credentials.
- Single-instance behavior is correctly described as `flock` plus `NSRunningApplication`, not a port probe.
- Packaging identity, signing procurement, OS/architecture decisions, pinned-metric UX, non-required Windows CI, crash diagnostics, continuous documentation, partial release failure, and schedule contingency were moved to appropriate phases.
- Candidate A is now a reasonable working preference rather than an unsupported Swift/WinRT conclusion. The official Swift toolchain claim for x64 and ARM64 is also current. [Swift Windows installation](https://www.swift.org/install/windows/)

The following round-1 issues were not fully or correctly resolved:

- **System proxy was reintroduced as if it were parity.** The plan specifies WinHTTP/registry system-proxy support in the blocker table and Phase 4. Current behavior is only the explicit `~/.openusage/config.json` proxy, default off, and explicitly “not a system-wide proxy.” [docs/proxy.md](/C:/Users/yildi/Repos/openusage/docs/proxy.md:3), [ProxyConfig.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Services/ProxyConfig.swift:32). This is new scope and still needs an owner decision.
- **Cross-target access control and composition-root injection remain implicit.** There are no `public` or `package` declarations in the proposed core areas; even `ProviderRuntime` is internal. [ProviderRuntime.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Providers/ProviderRuntime.swift:21). Numerous provider initializers still default to macOS concrete implementations such as `SecurityKeychainAccessor`, `SQLiteCLIAccessor`, and `URLSessionHTTPClient`. A target graph alone does not resolve either problem.
- **The unsupported “64k DLL symbol-export limit” rationale remains.** The upstream project documents mixed CMake/SPM builds, potentially newer toolchains, and slow debug rebuilds, but not this claimed causal explanation. The repository link should also use its current name. [Swift/WinRT repository](https://github.com/thebrowsercompany/swift-winrt)
- **The existing documentation inconsistencies were only partially scheduled.** Phase 1 names `docs/architecture.md`, but not the incorrect `NSPopover` statement in [AGENTS.md](/C:/Users/yildi/Repos/openusage/AGENTS.md:26). [docs/architecture.md](/C:/Users/yildi/Repos/openusage/docs/architecture.md:13) still lists five providers while [AppContainer.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/App/AppContainer.swift:58) registers nine.

## 2. Remaining factual errors

- **The ~9.3k figure is a correct folder subtotal, but not a standalone “core” or complete rewrite scope.** `Providers/` and `Pricing/` depend transitively on models, HTTP/filesystem/process abstractions, logging, parsing, date formatting, resource lookup, and stores. The document should call 9.3k “the Providers/Pricing subtotal” and defer the actual reusable-core size to the portability inventory.
- **The SwiftUI blocker table is incomplete.** It identifies `PlanWidget.swift` and `LayoutStore.swift`, but portable models also depend on `IconSource`, which is declared inside the SwiftUI-heavy [ProviderIconShape.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Support/ProviderIconShape.swift:4). Both [Provider.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Models/Provider.swift:7) and [WidgetData.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Models/WidgetData.swift:19) therefore have an indirect UI dependency.
- **The Codex source row omits an existing fallback.** [CodexAuthStore.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Providers/Codex/CodexAuthStore.swift:90) checks both `~/.config/codex/auth.json` and `~/.codex/auth.json`, unless `CODEX_HOME` overrides them.
- **The “target architecture” is not valid if candidate D wins.** The diagram and Phase 1 unconditionally require a shared Swift `OpenUsageCore`, while candidate D is described as a first-class full-.NET fallback. Candidate D needs an explicit alternate Phase 1 path.

I found no remaining factual problem with the LOC counts, registered provider count, notification defaults, API methods, credential write-back statement, or single-instance description.

## 3. Remaining gaps and risks

- Phase 0 says “each candidate” must produce a production-shaped spike, but B is optional and D is scored on paper. The gating is reasonable for a solo maintainer, but the wording and evidence requirements should agree.
- Scanner sharing semantics are recognized, but no actual filesystem seam is required. [IncrementalJSONLScanner.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Providers/IncrementalJSONLScanner.swift:23) directly enumerates and reads through `FileManager`; Windows sharing flags and race handling need an injectable adapter.
- Portable telemetry still obtains version and persistence identity from `Bundle.main`. [TelemetryRecorder.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Stores/TelemetryRecorder.swift:110), [TelemetryStore.swift](/C:/Users/yildi/Repos/openusage/Sources/OpenUsage/Stores/TelemetryStore.swift:28). The target split needs an app-metadata/identity input, otherwise Windows telemetry can report the fallback version or use the wrong defaults domain.
- Phase 2’s exit criterion says “natively-available providers,” which could accidentally exclude API-key-only OpenRouter and Z.ai. It should cover every v1 provider classified as native **or API-key-only**, excluding only explicitly unavailable/WSL-only cases.
- Credential-file ACLs, updater signature verification, downgrade rejection, locked-binary handling, and interrupted-update recovery remain under-specified. Signing every artifact is necessary but does not prove the updater verifies those signatures.
- Real-provider verification still lacks an explicit prerequisites list for accounts, paid tiers, and redacted evidence. That remains a schedule risk for the proposed three-to-five-week Phase 2.

## 4. Final actionable edits

1. Mark system-proxy discovery as optional new scope requiring Phase-0 owner approval; keep config-file proxy behavior as the parity baseline.
2. Add explicit Phase-1 tasks for `package`/`public` API design, removing platform-concrete default arguments from shared targets, and platform-specific composition roots.
3. Relabel 9.3k as the Providers/Pricing subtotal and add an alternate Phase-1 sequence if candidate D is selected.
4. Add the `IconSource`, scanner filesystem, and app metadata/identity seams to the portability inventory requirements.
5. Remove the unsupported 64k-symbol claim, update the Swift/WinRT link, and reconcile the Phase-0 “each candidate” language with the actual gated spikes.
6. Tighten Phase 2 and Phase 5 acceptance criteria: include API-key-only providers, account/evidence prerequisites, user-only credential ACLs, Authenticode verification, downgrade prevention, and interrupted-update tests. Explicitly include the stale `AGENTS.md` and provider-list documentation corrections.

**Overall verdict: APPROVE WITH MINOR EDITS**