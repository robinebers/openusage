import Foundation

enum MenuBarLimit: String, Hashable, Sendable, CaseIterable {
    case iconOnly
    case upToOne
    case upToTwo
    case upToThree
    case upToFour
    case upToFive

    var count: Int {
        switch self {
        case .iconOnly: 0
        case .upToOne: 1
        case .upToTwo: 2
        case .upToThree: 3
        case .upToFour: 4
        case .upToFive: 5
        }
    }

    var label: String {
        self == .iconOnly ? "App Icon Only" : "Up to \(count)"
    }
}
