import Foundation

public struct UsageReadResult: Sendable {
    public let data: Data
    public let warnings: [String]
}

public enum UsageReaderError: LocalizedError, Sendable {
    case unknownProvider(String)
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let providerID):
            "Unknown provider: \(providerID)"
        case .refreshFailed(let message):
            "Refresh failed: \(message)"
        }
    }
}

/// One-shot access to the same provider cache and refresh engine used by the menu-bar app.
/// It owns no timer, local server, status item, updater, or other long-lived app service.
@MainActor
public struct UsageReader {
    private let defaults: UserDefaults
    private let providersOverride: [ProviderRuntime]?

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
        self.providersOverride = nil
    }

    init(userDefaults: UserDefaults, providers: [ProviderRuntime]) {
        self.defaults = userDefaults
        self.providersOverride = providers
    }

    public func read(providerID requestedProviderID: String? = nil, force: Bool = false) async throws -> UsageReadResult {
        // The launch account pass (see `ProviderAccountAssembly`): resolves each family's default
        // account so cached snapshots are guarded — and refreshed ones stamped — with the correct
        // account, and finds the extra Claude cards the catalog must build (the CLI must know the
        // same card set as the app, or family matching would answer differently between the two).
        // Skipped when a test injects its own providers — they have no real homes to read.
        //
        // Warm the login-shell capture FIRST (off-main, one bounded subprocess). Identity-relevant
        // keys are pinned to the persisted shell-environment snapshot, but a CLI spawned without the
        // user's shell exports AND without a snapshot (the app never ran here) still needs the live
        // capture warm before the identity read — a MainActor read never triggers the capture itself,
        // so identity would read one home while the providers' off-main reads (which do trigger it)
        // fetch usage from another. From an interactive terminal the capture is redundant but harmless.
        if providersOverride == nil {
            await Task.detached(priority: .userInitiated) {
                _ = LoginShellEnvironment.shared.ensureCaptured()
            }.value
        }
        let accountAssembly = providersOverride == nil
            ? ProviderAccountAssembly.make(defaults: defaults, waitsForLoginShell: false)
            : ProviderAccountAssembly(identityKeysByCard: [:])
        let providers = providersOverride ?? ProviderCatalog.make(
            defaults: defaults,
            claudeCards: accountAssembly.claudeCards,
            defaultClaudeExtraLogRoots: accountAssembly.defaultClaudeExtraLogRoots
        )
        let registry = WidgetRegistry.from(providers)
        let knownIDs = Set(registry.providers.map(\.id))
        let enablement = ProviderEnablementStore(defaults: defaults)
        // A requested id names cards by plain string matching — an exact card id, or a family id
        // naming all of that family's cards — mirroring the local HTTP API exactly (see
        // `LocalUsageAPI.State.matchingCardIDs`). Never resolved from runtime state: the same
        // request names the same cards no matter who is logged in or what's enabled.
        let requestedToken = requestedProviderID?.lowercased()
        let matchedIDs: Set<String>? = requestedToken.map { token in
            knownIDs.filter { $0 == token || ProviderAccountID.family(of: $0) == token }
        }
        if let requestedToken, let matchedIDs, matchedIDs.isEmpty {
            throw UsageReaderError.unknownProvider(requestedToken)
        }

        let includesProvider: @MainActor (String) -> Bool = { id in
            matchedIDs?.contains(id) ?? enablement.isEnabled(id)
        }
        let cache = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true)
        let allProviderIDs = registry.providers.map(\.id)
        // The same account guard the app applies at launch: an entry that provably belongs to another
        // account (swap since it was written) is never served, and its provider counts as needing a
        // refresh even while the stale entry is TTL-fresh.
        let staleAccountStampIDs = Set(allProviderIDs.filter {
            cache.hasStaleAccountStamp(providerID: $0, currentIdentityKey: accountAssembly.identityKeysByCard[$0])
        })
        let cachedSnapshots = cache.loadSnapshots(providerIDs: allProviderIDs)
            .filter { providerID, _ in !staleAccountStampIDs.contains(providerID) }
        let savedOrder = LayoutPersistence(
            defaults: defaults,
            storageKey: "openusage.layout.v1"
        ).loadProviderOrder() ?? []
        let orderedIDs = registry.orderedProviderIDs(savedOrder: savedOrder)
        let enabledOrderedIDs = orderedIDs.filter(includesProvider)
        let needsRefresh = force || enabledOrderedIDs.contains {
            cache.snapshot(providerID: $0) == nil || staleAccountStampIDs.contains($0)
        }
        var snapshots = cachedSnapshots
        var warnings: [String] = []
        var errors: [String: String] = [:]

        if needsRefresh {
            LoginShellEnvironment.shared.prewarm()
            let dataStore = WidgetDataStore(
                registry: registry,
                providers: providers,
                cache: cache,
                defaults: defaults,
                isProviderEnabled: includesProvider,
                // The CLI shares the app's snapshot cache, so its writes must carry the same account
                // stamp — an unstamped claude/codex entry would be discarded at the app's next launch.
                providerIdentityKeys: accountAssembly.identityKeysByCard
            )
            if let matchedIDs {
                for providerID in orderedIDs.filter(matchedIDs.contains) {
                    _ = await dataStore.refresh(providerID: providerID, force: force)
                }
            } else {
                await dataStore.refreshAll(force: force)
            }
            if providersOverride == nil {
                await PersistentJSONLScanCaches.flushPendingWrites()
            }
            snapshots = dataStore.snapshots
            errors = dataStore.providerErrors
            warnings = orderedIDs
                .compactMap { id in errors[id].map { "\(id): \($0)" } }
        }

        // CLI output is human-read: resolve card titles against the persisted account registry so
        // renames show, matching the app's UI and HTTP API. Injected-provider tests use their own
        // defaults suite, so this is a no-op there.
        let accountTitles = ProviderAccountsStore(defaults: defaults).resolvedDisplayNamesByCardID
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: enabledOrderedIDs,
            knownIDs: knownIDs,
            snapshots: snapshots,
            limitDescriptors: registry.limitDescriptorsByProvider,
            errors: errors
        )
        .resolvingDisplayNames(accountTitles)
        let path = requestedToken.map { "/v1/limits/\($0)" } ?? "/v1/limits"
        let response = LocalUsageAPI.respond(method: "GET", path: path, state: state)
        guard let data = response.body else {
            // Unreachable in practice: the token was validated above and the limits routes always
            // produce a body for a known token. Fail loudly rather than print nothing.
            throw UsageReaderError.refreshFailed(warnings.first ?? "local read produced no data")
        }
        return UsageReadResult(data: data, warnings: warnings)
    }

}
