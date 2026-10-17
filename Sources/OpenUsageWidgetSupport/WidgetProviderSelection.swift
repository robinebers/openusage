import Foundation

public enum WidgetBridgeReadStatus: Sendable {
    case loaded
    case missing
    case corrupt
    case unsupported
}

/// Which providers a widget offers and shows. The list is whatever the host exported, so new providers
/// and extra account cards need no extension changes.
public enum WidgetProviderSelection {
    public struct Option: Hashable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public enum Entry: Equatable, Sendable {
        case provider(WidgetProviderRecord)
        case missingData(String?)
        case corruptData(String?)
        case unsupportedData(String?)
        case missingProvider(String)

        public var providerID: String? {
            switch self {
            case .provider(let provider): provider.id
            case .missingData(let id), .corruptData(let id), .unsupportedData(let id): id
            case .missingProvider(let id): id
            }
        }
    }

    /// Bridge errors take precedence even before a widget has a saved provider. Only a loaded bridge
    /// can choose the default provider or report that the saved provider is no longer exported.
    public static func entry(
        configuredID: String?,
        bridgeStatus: WidgetBridgeReadStatus,
        in providers: [WidgetProviderRecord]
    ) -> Entry {
        switch bridgeStatus {
        case .missing:
            return .missingData(configuredID)
        case .corrupt:
            return .corruptData(configuredID)
        case .unsupported:
            return .unsupportedData(configuredID)
        case .loaded:
            guard let selectedID = configuredID ?? defaultProviderID(in: providers) else {
                return .missingData(nil)
            }
            guard let provider = providers.first(where: { $0.id == selectedID }) else {
                return .missingProvider(selectedID)
            }
            return .provider(provider)
        }
    }

    /// Resolves saved picker ids. An id the host no longer exports (a removed account card, or no bridge
    /// file yet) keeps a placeholder named by its id, so the widget reports it missing instead of
    /// silently switching to another provider.
    public static func resolve(
        _ ids: [String],
        in providers: [WidgetProviderRecord]
    ) -> [Option] {
        ids.map { id in
            Option(id: id, name: providers.first { $0.id == id }?.displayName ?? id)
        }
    }

    /// Enabled providers first; every exported provider when none is enabled.
    public static func suggested(in providers: [WidgetProviderRecord]) -> [WidgetProviderRecord] {
        let enabled = providers.filter(\.isEnabled)
        return enabled.isEmpty ? providers : enabled
    }

    /// The provider an unconfigured widget shows.
    public static func defaultProviderID(in providers: [WidgetProviderRecord]) -> String? {
        suggested(in: providers).first?.id
    }
}
