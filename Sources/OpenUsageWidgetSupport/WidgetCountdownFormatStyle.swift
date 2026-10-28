import Foundation
import SwiftUI

/// A live countdown that reaches "soon" at the reset instant and never counts elapsed time as time left.
public struct WidgetCountdownFormatStyle: DiscreteFormatStyle {
    public enum Style: String, Codable, Hashable, Sendable {
        case relative
        case leadingUnit
        case minutes
    }

    public let resetAt: Date
    public let style: Style

    public init(resetAt: Date, style: Style) {
        self.resetAt = resetAt
        self.style = style
    }

    public func format(_ date: Date) -> String {
        guard date < resetAt else { return "soon" }
        if style == .relative {
            let fields: Set<Date.ComponentsFormatStyle.Field> =
                resetAt.timeIntervalSince(date) >= 86_400 ? [.day, .hour] : [.hour, .minute]
            return Date.ComponentsFormatStyle(style: .abbreviated, fields: fields).format(date..<resetAt)
        }
        return String(offsetFormat.format(date).characters)
    }

    public func discreteInput(after date: Date) -> Date? {
        guard date < resetAt else { return nil }
        return min(offsetFormat.discreteInput(after: date) ?? resetAt, resetAt)
    }

    public func discreteInput(before date: Date) -> Date? {
        if date >= resetAt {
            return Date(timeIntervalSinceReferenceDate: resetAt.timeIntervalSinceReferenceDate.nextDown)
        }
        return offsetFormat.discreteInput(before: date)
    }

    private var offsetFormat: SystemFormatStyle.DateOffset {
        let fields: Set<Date.ComponentsFormatStyle.Field> = style == .minutes ? [.minute] : [.day, .hour, .minute]
        return .offset(to: resetAt, allowedFields: fields, maxFieldCount: style == .relative ? 2 : 1, sign: .never)
    }
}
