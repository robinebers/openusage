import Foundation

public struct UsageReadResult: Sendable {
    public let data: Data
    public let warnings: [String]
}

public enum UsageReaderError: LocalizedError, Sendable {
    case unknownProvider(String)
    case noCachedSnapshot(String)
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let providerID):
            "Unknown provider: \(providerID)"
        case .noCachedSnapshot(let providerID):
            "No cached usage for \(providerID). Run with --force to fetch it."
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
        let providerID = requestedProviderID?.lowercased()
        let providers = providersOverride ?? ProviderCatalog.make(defaults: defaults)
        let registry = WidgetRegistry.from(providers)
        let knownIDs = Set(registry.providers.map(\.id))
        if let providerID, !knownIDs.contains(providerID) {
            throw UsageReaderError.unknownProvider(providerID)
        }

        let enablement = ProviderEnablementStore(defaults: defaults)
        let includesProvider: @MainActor (String) -> Bool = { id in
            providerID.map { $0 == id } ?? enablement.isEnabled(id)
        }
        let cache = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true)
        let allProviderIDs = registry.providers.map(\.id)
        let cachedSnapshots = cache.loadSnapshots(providerIDs: allProviderIDs)
        let savedOrder = LayoutPersistence(
            defaults: defaults,
            storageKey: "openusage.layout.v1"
        ).loadProviderOrder() ?? []
        let orderedIDs = registry.orderedProviderIDs(savedOrder: savedOrder)
        let enabledOrderedIDs = orderedIDs.filter(includesProvider)
        let needsRefresh = force || enabledOrderedIDs.contains { cache.snapshot(providerID: $0) == nil }
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
                isProviderEnabled: includesProvider
            )
            if let providerID {
                _ = await dataStore.refresh(providerID: providerID, force: force)
            } else {
                await dataStore.refreshAll(force: force)
            }
            snapshots = dataStore.snapshots
            errors = dataStore.providerErrors
            warnings = orderedIDs
                .compactMap { id in errors[id].map { "\(id): \($0)" } }
        }

        let state = LocalUsageAPI.State(
            enabledOrderedIDs: enabledOrderedIDs,
            knownIDs: knownIDs,
            snapshots: snapshots,
            limitDescriptors: registry.limitDescriptorsByProvider,
            errors: errors
        )
        let path = providerID.map { "/v1/limits/\($0)" } ?? "/v1/limits"
        let response = LocalUsageAPI.respond(method: "GET", path: path, state: state)
        guard let data = response.body else {
            if let warning = warnings.first {
                throw UsageReaderError.refreshFailed(warning)
            }
            throw UsageReaderError.noCachedSnapshot(providerID ?? "enabled providers")
        }
        return UsageReadResult(data: data, warnings: warnings)
    }

}
