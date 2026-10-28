import Foundation

enum ResetDisplayMode: String, Hashable, Sendable, CaseIterable {
    case relative
    case absolute

    var label: String {
        switch self {
        case .relative: return "Countdown"
        case .absolute: return "Exact Time"
        }
    }

    mutating func toggle() {
        self = self == .relative ? .absolute : .relative
    }
}
