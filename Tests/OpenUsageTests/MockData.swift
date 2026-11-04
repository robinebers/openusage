import SwiftUI
@testable import OpenUsage

enum MockData {
    static let claude = Provider(id: "claude", kind: .claude)
    static let codex = Provider(id: "codex", kind: .codex)
    static let cursor = Provider(id: "cursor", kind: .cursor)

    static let providers: [Provider] = [claude, codex, cursor]

    static let descriptors: [WidgetDescriptor] = [
        percent(key: "session", provider: claude, title: "Session", used: 0),
        percent(key: "weekly", provider: claude, title: "Weekly", used: 34),
        amount(key: "extra", provider: claude, title: "Extra usage", used: 217.59),
        amount(key: "today", provider: claude, title: "Today", used: 64.20),

        percent(key: "session", provider: codex, title: "Session", used: 80),
        percent(key: "weekly", provider: codex, title: "Weekly", used: 20),
        countBounded(key: "credits", provider: codex, title: "Extra Usage", used: 320, limit: 1000),
        amount(key: "today", provider: codex, title: "Today", used: 569.09),

        percent(key: "usage", provider: cursor, title: "Usage", used: 98),
        amount(key: "credits", provider: cursor, title: "Credits", used: 12.48),
        countBounded(key: "requests", provider: cursor, title: "Requests", used: 412, limit: 500),
        amount(key: "today", provider: cursor, title: "Today", used: 12.48)
    ]

    static func descriptors(for providerID: String) -> [WidgetDescriptor] {
        descriptors.filter { $0.providerID == providerID }
    }

    private static func percent(key: String, provider: Provider, title: String, used: Double) -> WidgetDescriptor {
        descriptor(
            key,
            provider,
            title,
            WidgetData(title: title, kind: .percent, used: used, limit: 100)
        )
    }

    private static func countBounded(key: String, provider: Provider, title: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(key, provider, title, WidgetData(title: title, kind: .count, used: used, limit: limit))
    }

    private static func amount(key: String, provider: Provider, title: String, used: Double) -> WidgetDescriptor {
        descriptor(
            key,
            provider,
            title,
            WidgetData(title: title, kind: .dollars, used: used, limit: nil)
        )
    }

    private static func descriptor(
        _ key: String,
        _ provider: Provider,
        _ title: String,
        _ data: WidgetData
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            provider: provider,
            key: key,
            metricLabel: title,
            sample: data
        )
    }
}

extension WidgetRegistry {
    static let mock = WidgetRegistry(
        providers: MockData.providers,
        descriptors: MockData.descriptors
    )
}
