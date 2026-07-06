import AppIntents

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
        let requested = Set(identifiers)
        return WidgetProviderCatalog.all.filter { requested.contains($0.id) }
    }

    func allEntities() async throws -> [WidgetProviderEntity] {
        WidgetProviderCatalog.all
    }

    func suggestedEntities() async throws -> [WidgetProviderEntity] {
        let enabledIDs = WidgetBridgeReader.enabledProviderIDs()
        let enabled = WidgetProviderCatalog.all.filter { enabledIDs.contains($0.id) }
        return enabled.isEmpty ? WidgetProviderCatalog.all : enabled
    }
}

enum WidgetProviderCatalog {
    static let all: [WidgetProviderEntity] = [
        .init(id: "claude", name: "Claude"),
        .init(id: "codex", name: "Codex"),
        .init(id: "cursor", name: "Cursor"),
        .init(id: "antigravity", name: "Antigravity"),
        .init(id: "copilot", name: "Copilot"),
        .init(id: "devin", name: "Devin"),
        .init(id: "grok", name: "Grok"),
        .init(id: "openrouter", name: "OpenRouter"),
        .init(id: "zai", name: "Z.ai"),
    ]

    static func entity(id: String) -> WidgetProviderEntity? {
        all.first { $0.id == id }
    }
}
