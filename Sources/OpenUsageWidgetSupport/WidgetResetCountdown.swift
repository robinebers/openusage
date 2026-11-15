import Foundation

/// Evaluated when the extension creates a view. Only system timer text or a plain string is archived.
public enum WidgetResetCountdown: Equatable, Sendable {
    case remaining(ClosedRange<Date>)
    case due

    public init(resetAt: Date, at entryDate: Date) {
        self = entryDate < resetAt ? .remaining(entryDate...resetAt) : .due
    }

    /// Live timer text has no ideal width. Reserve its widest hours/minutes/seconds representation.
    public var widthTemplate: String {
        switch self {
        case .remaining(let interval):
            let hours = Int(ceil(interval.upperBound.timeIntervalSince(interval.lowerBound)) / 3_600)
            return hours == 0 ? "88:88" : String(repeating: "8", count: String(hours).count) + ":88:88"
        case .due:
            return "soon"
        }
    }
}
