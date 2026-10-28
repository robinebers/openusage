import SwiftUI
@testable import OpenUsage

/// Test fixtures: sample providers and the widgets they register (mirroring OpenUsage's real
/// metrics and units). Lives in the test target only — the app builds its registry from the
/// live `ProviderRuntime`s.
enum MockData {
    // MARK: - Providers
    static let claude = Provider(id: "claude", displayName: "Claude", icon: "claude")
    static let codex = Provider(id: "codex", displayName: "Codex", icon: "codex")
    static let cursor = Provider(id: "cursor", displayName: "Cursor", icon: "cursor")

    static let providers: [Provider] = [claude, codex, cursor]

    // MARK: - Registered widgets (limit => bar; no limit => value)
    static let descriptors: [WidgetDescriptor] = [
        // Claude — percent limits (bars) + dollar amounts (values)
        percent(id: "claude.session", provider: claude, title: "Session", used: 0),
        percent(id: "claude.weekly", provider: claude, title: "Weekly", used: 34),
        amount(id: "claude.extra", provider: claude, title: "Extra usage", used: 217.59),
        amount(id: "claude.today", provider: claude, title: "Today", used: 64.20),

        // Codex — percent limits (bars), credits as a counted limit (bar), dollars (value)
        percent(id: "codex.session", provider: codex, title: "Session", used: 80),
        percent(id: "codex.weekly", provider: codex, title: "Weekly", used: 20),
        countBounded(id: "codex.credits", provider: codex, title: "Extra Usage", used: 320, limit: 1000),
        amount(id: "codex.today", provider: codex, title: "Today", used: 569.09),

        // Cursor — usage % (bar), credits balance (value), requests count with cap (bar), dollars (value)
        percent(id: "cursor.usage", provider: cursor, title: "Usage", used: 98),
        amount(id: "cursor.credits", provider: cursor, title: "Credits", used: 12.48),
        countBounded(id: "cursor.requests", provider: cursor, title: "Requests", used: 412, limit: 500),
        amount(id: "cursor.today", provider: cursor, title: "Today", used: 12.48)
    ]

    static func descriptor(_ id: String) -> WidgetDescriptor? { descriptors.first { $0.id == id } }
    static func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }
    static func descriptors(for providerID: String) -> [WidgetDescriptor] {
        descriptors.filter { $0.providerID == providerID }
    }

    // MARK: - Descriptor builders (one display name = row + metric label)
    private static func percent(id: String, provider: Provider, title: String, used: Double) -> WidgetDescriptor {
        descriptor(
            id,
            provider,
            title,
            WidgetData(title: title, kind: .percent, used: used, limit: 100)
        )
    }

    private static func countBounded(id: String, provider: Provider, title: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, provider, title, WidgetData(title: title, kind: .count, used: used, limit: limit))
    }

    private static func amount(id: String, provider: Provider, title: String, used: Double) -> WidgetDescriptor {
        descriptor(
            id,
            provider,
            title,
            WidgetData(title: title, kind: .dollars, used: used, limit: nil)
        )
    }

    private static func descriptor(
        _ id: String,
        _ provider: Provider,
        _ title: String,
        _ data: WidgetData
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: title,
            sample: data
        )
    }
}

extension WidgetRegistry {
    /// The fixture-backed registry tests use in place of live providers.
    static let mock = WidgetRegistry(
        providers: MockData.providers,
        descriptors: MockData.descriptors
    )
}
