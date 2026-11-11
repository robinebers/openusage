import Foundation

struct MetricValue: Hashable, Sendable, Codable {
    var number: Double
    var kind: MetricKind
    var label: String?
    var currencyCode: String?
}
