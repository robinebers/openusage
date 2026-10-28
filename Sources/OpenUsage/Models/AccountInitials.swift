import Foundation

enum AccountInitials {
    static func tag(for name: String) -> String {
        let initials = name.split(whereSeparator: \.isWhitespace).compactMap(\.first)
        guard let first = initials.first else { return "" }
        let letters = initials.count > 1 ? [first, initials[initials.count - 1]] : [first]
        return String(letters).uppercased()
    }
}
