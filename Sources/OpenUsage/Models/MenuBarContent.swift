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
    var groupsByProvider = false

    struct Group: Identifiable {
        let provider: Provider
        var items: [Item]
        var id: String { items[0].id }
    }

    var groups: [Group] {
        var groups: [Group] = []
        for item in items {
            if groupsByProvider, let index = groups.firstIndex(where: { $0.provider.id == item.provider.id }) {
                groups[index].items.append(item)
            } else {
                groups.append(Group(provider: item.provider, items: [item]))
            }
        }
        return groups
    }

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

    /// Always Show uses the classic provider strip; the attention-only strip keeps its urgency order.
    static func build(board: PriorityBoard, limit: MenuBarLimit, alwaysShows: Bool = false) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(items: []) }
        if alwaysShows { return classicContent(board: board, limit: limit) }
        let shown = board.runningOut.prefix(limit.count).map { item($0.provider, $0.line) }
        return MenuBarContent(items: shown, overflow: max(0, board.runningOut.count - shown.count))
    }

    private static func item(_ provider: Provider, _ line: DashboardLine) -> MenuBarContent.Item {
        let label = line.data.title
        return MenuBarContent.Item(id: line.id, provider: provider, label: label,
                                   shortLabel: shortLabel(label), value: line.data.menuBarValue)
    }

    private static func classicContent(board: PriorityBoard, limit: MenuBarLimit) -> MenuBarContent {
        var providerIDs: [String] = []
        for metric in board.reportedMetrics where !providerIDs.contains(metric.provider.id) {
            providerIDs.append(metric.provider.id)
        }
        let shown = providerIDs.prefix(limit.count).flatMap { id -> [MenuBarContent.Item] in
            let metrics = board.reportedMetrics.filter { $0.provider.id == id }
            let pins = Set(board.pinned.filter { $0.provider.id == id }.map(\.id)
                           + board.usedUp.filter { $0.provider.id == id && $0.isPinned }.map(\.id))
            let pinned = metrics.filter { pins.contains($0.id) }
            // Explicit dashboard pins select the pair; otherwise preserve the classic default pair.
            let keys = classicKeys[metrics[0].provider.kind] ?? []
            let defaults = metrics.filter { keys.contains($0.line.descriptor.key) }
            let selected = pinned.isEmpty ? (defaults.isEmpty ? metrics : defaults) : pinned
            return selected.prefix(2).map { item($0.provider, $0.line) }
        }
        guard !shown.isEmpty else { return MenuBarContent(items: []) }
        return MenuBarContent(items: shown, overflow: max(0, providerIDs.count - limit.count), groupsByProvider: true)
    }

    /// The default menu-bar stars from 0.7.4, using today's equivalent keys.
    private static let classicKeys: [ProviderKind: Set<String>] = [
        .claude: ["session", "weekly"], .codex: ["session", "weekly"],
        .antigravity: ["geminiPro", "geminiWeekly"], .cursor: ["auto", "api"],
        .copilot: ["premium"], .openrouter: ["credits", "balance"], .zai: ["session", "weekly"]
    ]

    static func shortLabel(_ label: String) -> String {
        var words = label.split(separator: " ")
        guard words.count > 1, let last = words.last, genericWords.contains(last.lowercased()) else { return label }
        words.removeLast()
        return words.joined(separator: " ")
    }
}
