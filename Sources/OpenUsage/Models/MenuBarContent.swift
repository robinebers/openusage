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
        // Running Out and Used Up come before Pinned, so a pin never pushes an urgent limit past the cap.
        let lines = (board.attention + board.usedUp).map { ($0.provider, $0.line) } + board.pinned.map { ($0.provider, $0.line) }
        let shown = lines.prefix(limit.count).map { provider, line in
            let label = line.data.title
            return MenuBarContent.Item(
                id: line.id,
                provider: provider,
                label: label,
                shortLabel: shortLabel(label),
                value: line.data.menuBarValue
            )
        }
        return MenuBarContent(items: shown, overflow: lines.count - shown.count)
    }

    static func shortLabel(_ label: String) -> String {
        var words = label.split(separator: " ")
        guard words.count > 1, let last = words.last, genericWords.contains(last.lowercased()) else { return label }
        words.removeLast()
        return words.joined(separator: " ")
    }
}
