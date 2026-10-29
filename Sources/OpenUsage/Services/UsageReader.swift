import Foundation

public struct UsageReadResult: Sendable {
    public let data: Data
    public let hasSnapshots: Bool
}

public enum UsageReaderError: Error, Sendable {
    case unknownProvider(String)
}

@MainActor
public enum UsageReader {
    public static func read(_ defaults: UserDefaults, providerID: String? = nil) throws -> UsageReadResult {
        var accounts = AccountStore.load(from: defaults).accounts
        if let token = providerID?.lowercased() {
            accounts = accounts.filter { $0.cardID == token || $0.kind.rawValue == token }
            guard !accounts.isEmpty else { throw UsageReaderError.unknownProvider(token) }
        }
        let registry = WidgetRegistry(
            providers: accounts.map(AccountProviderRuntime.provider(for:)),
            descriptors: accounts.flatMap(AccountProviderRuntime.widgetDescriptors(for:))
        )
        let snapshots = ProviderSnapshotCache(userDefaults: defaults).load()
        let data = LimitsEnvelope.encode(LimitsEnvelope.Input(registry: registry, snapshots: snapshots))
        return UsageReadResult(data: data, hasSnapshots: accounts.contains { snapshots[$0.cardID] != nil })
    }
}
