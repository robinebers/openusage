import Foundation

enum ProgressFormat: Hashable, Sendable, Codable {
    case percent
    case dollars
    case currency(code: String)
    case count(suffix: String)

    var metricKind: MetricKind {
        switch self {
        case .percent:
            return .percent
        case .dollars, .currency:
            return .dollars
        case .count:
            return .count
        }
    }

    var currencyCode: String? {
        guard case .currency(let code) = self else { return nil }
        return code
    }
}

enum MetricLine: Hashable, Sendable, Codable {
    case values(label: String, values: [MetricValue], expiriesAt: [Date] = [])
    case progress(
        label: String,
        used: Double,
        limit: Double,
        format: ProgressFormat,
        resetsAt: Date? = nil,
        periodDurationMs: Int? = nil
    )
    case badge(label: String, text: String)

    var label: String {
        switch self {
        case .progress(let label, _, _, _, _, _),
             .values(let label, _, _),
             .badge(let label, _):
            return label
        }
    }
}
