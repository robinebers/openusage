import Foundation

enum OpenUsageISO8601 {
    static func string(from date: Date) -> String {
        formatter(fractionalSeconds: true).string(from: date)
    }

    static func date(from value: String) -> Date? {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix(" UTC") { s = s.dropLast(4) + "Z" }
        if let match = s.prefixMatch(of: /(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})?/) {
            let (_, day, time, digits, zone) = match.output
            if match.range.upperBound == s.endIndex {
                let fraction = digits.map { "." + $0.prefix(3) + String(repeating: "0", count: max(0, 3 - $0.count)) } ?? ""
                s = "\(day)T\(time)\(fraction)\(zone ?? "Z")"
            } else {
                s = "\(day)T\(s[time.startIndex...])"
            }
        }
        return formatter(fractionalSeconds: true).date(from: s) ?? formatter(fractionalSeconds: false).date(from: s)
    }

    // ISO8601DateFormatter is expensive to construct and is hit on every snapshot decode and
    // encode, so the two fixed configurations are built once. `ISO8601DateFormatter` is thread-safe for
    // parsing/formatting, and parsing here runs on the main-actor refresh path; `nonisolated(unsafe)`
    // shares the immutable instances without per-call allocation.
    private nonisolated(unsafe) static let fractionalFormatter = makeFormatter(fractionalSeconds: true)
    private nonisolated(unsafe) static let plainFormatter = makeFormatter(fractionalSeconds: false)

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        fractionalSeconds ? fractionalFormatter : plainFormatter
    }

    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
