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
        let accounts = AccountStore.load(from: defaults)
        var providerIDs = accounts.map(\.cardID)
        if let token = providerID?.lowercased() {
            providerIDs = accounts.filter { $0.cardID == token || $0.kind.rawValue == token }.map(\.cardID)
            guard !providerIDs.isEmpty else { throw UsageReaderError.unknownProvider(token) }
        }
        var limitDescriptors: [String: [WidgetDescriptor]] = [:]
        for descriptor in accounts.flatMap(AccountProviderRuntime.widgetDescriptors(for:))
        where !descriptor.limitResources.isEmpty {
            limitDescriptors[descriptor.providerID, default: []].append(descriptor)
        }
        let snapshots = ProviderSnapshotCache(userDefaults: defaults).load().filter { providerIDs.contains($0.key) }
        let data = LimitsEnvelope.encode(LimitsEnvelope.Input(
            providerIDs: providerIDs,
            snapshots: snapshots,
            limitDescriptors: limitDescriptors
        ))
        return UsageReadResult(data: data, hasSnapshots: !snapshots.isEmpty)
    }
}
