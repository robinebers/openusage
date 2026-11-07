import Foundation

/// How every usage bar is filled: one flat colour, or a pixel dither.
enum LevelFillSetting: String, Hashable, Sendable, CaseIterable {
    case solid
    case dithered

    static let key = "levelFill"

    static var current: LevelFillSetting { UserDefaults.standard.enumValue(forKey: key, default: .solid) }

    var label: String {
        switch self {
        case .solid: return "Solid"
        case .dithered: return "Dithered"
        }
    }
}
