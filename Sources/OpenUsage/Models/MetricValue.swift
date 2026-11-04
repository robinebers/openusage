import Foundation

struct MetricValue: Hashable, Sendable, Codable {
    var number: Double
    var kind: MetricKind
    var label: String?
    var currencyCode: String?
    init(number: Double, kind: MetricKind, label: String? = nil, currencyCode: String? = nil) {
        self.number = number
        self.kind = kind
        self.label = label
        self.currencyCode = currencyCode
    }
}
