import Foundation

enum MetricKind: String, Hashable, Sendable, Codable {
    case percent
    case dollars
    case count
}
