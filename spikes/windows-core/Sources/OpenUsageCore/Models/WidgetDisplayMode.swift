import Foundation

enum WidgetDisplayMode: String, Hashable, Sendable, CaseIterable {
    case used
    case remaining

    /// "Left" mirrors the legacy app's wording for remaining headroom.
    var label: String {
        switch self {
        case .used: return "Used"
        case .remaining: return "Left"
        }
    }

    mutating func toggle() {
        self = self == .used ? .remaining : .used
    }
}
