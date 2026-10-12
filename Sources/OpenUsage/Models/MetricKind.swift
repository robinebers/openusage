import Foundation

/// How a metric's number is formatted. Mirrors OpenUsage's `format.kind`.
///
/// `String`-backed and `Codable` so it can ride on a `MetricValue` carried inside a cached
/// `MetricLine` (see `MetricValue`).
enum MetricKind: String, Hashable, Sendable, Codable {
    case percent      // used is 0...100
    case dollars      // money; USD by default, or MetricValue.currencyCode for unbounded values
    case count        // used is an absolute count (with an optional suffix)
}
