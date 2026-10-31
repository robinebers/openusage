import Foundation

struct MenuBarContent: Equatable {
    struct Metric: Equatable {
        let id: String
        let label: String
        let value: String
    }

    struct Group: Equatable {
        let provider: Provider
        let metrics: [Metric]
        var badge: String? = nil
    }

    let groups: [Group]

    var isEmpty: Bool { groups.isEmpty }

    var accessibilityText: String {
        groups.map { group in
            let metrics = group.metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return "\(group.provider.fullName) \(metrics)"
        }
        .joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    static func build(groups: [ProviderMetrics], data: (WidgetDescriptor) -> WidgetData) -> MenuBarContent {
        let resolvedGroups = groups.compactMap { group -> MenuBarContent.Group? in
            let metrics = group.metrics.compactMap { descriptor -> MenuBarContent.Metric? in
                let data = data(descriptor)
                guard data.hasData, !(data.hidesAtZero && data.values.allSatisfy { $0.number <= 0 }) else { return nil }
                return MenuBarContent.Metric(id: descriptor.id, label: trayLabel(descriptor.metricLabel), value: data.menuBarValue)
            }
            guard !metrics.isEmpty else { return nil }
            return MenuBarContent.Group(provider: group.provider, metrics: metrics)
        }
        return MenuBarContent(groups: badged(resolvedGroups))
    }

    private static func badged(_ groups: [MenuBarContent.Group]) -> [MenuBarContent.Group] {
        let families = Dictionary(grouping: groups.indices) { groups[$0].provider.kind }
        var result = groups
        for index in families.values.filter({ $0.count > 1 }).joined() {
            result[index].badge = AccountInitials.tag(for: groups[index].provider.accountName)
        }
        return result
    }

    private static func trayLabel(_ metricLabel: String) -> String {
        metricLabel.lowercased() == "today" ? "T" : metricLabel
    }
}
