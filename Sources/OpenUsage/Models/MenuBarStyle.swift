import Foundation

/// How the menu-bar item renders the pinned metrics: a `text` strip (provider icon + values, one
/// segment per pinned provider) or the compact `bars` glyph (up to four bounded-metric bars). Chosen in
/// Settings and persisted by `LayoutStore`; defaults to `.text`.
enum MenuBarStyle: String, Hashable, Sendable, CaseIterable {
    case text
    case bars

    var label: String {
        switch self {
        case .text: return "Text"
        case .bars: return "Bars"
        }
    }
}
