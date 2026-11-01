import Foundation

struct MenuBarContent: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let provider: Provider
        let label: String
        let shortLabel: String
        let value: String
        var badge: String? = nil
    }

    let items: [Item]
    var overflow = 0

    var isEmpty: Bool { items.isEmpty }

    var accessibilityText: String {
        let shown = items.map { "\($0.provider.fullName) \($0.label) \($0.value)" }
        let more = overflow > 0 ? ["\(overflow) more"] : []
        return (shown + more).joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    private static let genericWords: Set<String> = ["models", "bot", "usage"]

    static func build(board: PriorityBoard, limit: MenuBarLimit) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(items: []) }
        let shown = board.attention.prefix(limit.count).map { item in
            let label = item.line.descriptor.metricLabel
            return MenuBarContent.Item(
                id: item.id,
                provider: item.provider,
                label: label,
                shortLabel: shortLabel(label),
                value: item.data.menuBarValue
            )
        }
        return MenuBarContent(items: badged(shown), overflow: board.attention.count - shown.count)
    }

    static func shortLabel(_ label: String) -> String {
        var words = label.split(separator: " ")
        guard words.count > 1, let last = words.last, genericWords.contains(last.lowercased()) else { return label }
        words.removeLast()
        return words.joined(separator: " ")
    }

    private static func badged(_ items: [MenuBarContent.Item]) -> [MenuBarContent.Item] {
        let accounts = Dictionary(grouping: items, by: \.provider.kind).mapValues { Set($0.map(\.provider.id)).count }
        return items.map { item in
            var item = item
            if accounts[item.provider.kind, default: 0] > 1 {
                item.badge = AccountInitials.tag(for: item.provider.accountName)
            }
            return item
        }
    }
}
