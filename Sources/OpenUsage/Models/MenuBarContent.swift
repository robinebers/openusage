import Foundation

struct MenuBarContent: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let provider: Provider
        let label: String
        let shortLabel: String
        let value: String
    }

    let items: [Item]
    var overflow = 0
    var updateAvailable = false

    var isEmpty: Bool { items.isEmpty }

    var accessibilityText: String {
        let shown = items.map { "\($0.provider.fullName) \($0.label) \($0.value)" }
        let more = overflow > 0 ? ["\(overflow) more"] : []
        let update = updateAvailable ? ["Update available"] : []
        return (shown + more + update).joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    private static let genericWords: Set<String> = ["models", "bot", "usage"]

    static func build(board: PriorityBoard, limit: MenuBarLimit) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(items: []) }
        let shown = board.attention.prefix(limit.count).map { item in
            let label = item.data.title
            return MenuBarContent.Item(
                id: item.id,
                provider: item.provider,
                label: label,
                shortLabel: shortLabel(label),
                value: item.data.menuBarValue
            )
        }
        return MenuBarContent(items: shown, overflow: board.attention.count - shown.count)
    }

    static func shortLabel(_ label: String) -> String {
        var words = label.split(separator: " ")
        guard words.count > 1, let last = words.last, genericWords.contains(last.lowercased()) else { return label }
        words.removeLast()
        return words.joined(separator: " ")
    }
}
