import Foundation

enum WidgetDisplayMode: String, Hashable, Sendable, CaseIterable {
    case used
    case remaining

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
