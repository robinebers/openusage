import AppIntents
import OpenUsageWidgetSupport

struct ProviderWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider Usage"
    static let description = IntentDescription("Choose the provider shown in the widget.")

    @Parameter(title: "Provider")
    var provider: WidgetProviderEntity?

    init() {}

    init(provider: WidgetProviderEntity?) {
        self.provider = provider
    }
}

struct WidgetProviderEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider")
    static let defaultQuery = WidgetProviderEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct WidgetProviderEntityQuery: EntityQuery, EnumerableEntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetProviderEntity] {
        WidgetProviderSelection.resolve(identifiers, in: Self.providers()).map {
            WidgetProviderEntity(id: $0.id, name: $0.name)
        }
    }

    func allEntities() async throws -> [WidgetProviderEntity] {
        Self.providers().map(WidgetProviderEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetProviderEntity] {
        WidgetProviderSelection.suggested(in: Self.providers()).map(WidgetProviderEntity.init)
    }

    private static func providers() -> [WidgetProviderRecord] {
        WidgetBridgeReader.load().document?.providers ?? []
    }
}

private extension WidgetProviderEntity {
    init(_ provider: WidgetProviderRecord) {
        self.init(id: provider.id, name: provider.displayName)
    }
}
