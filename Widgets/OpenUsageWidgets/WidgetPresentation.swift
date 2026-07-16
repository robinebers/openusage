import Foundation

struct WidgetProviderContent: Hashable, Sendable {
    enum Health: String, Hashable, Sendable {
        case ready
        case warning
        case failed
        case noData
    }

    let id: String
    let displayName: String
    let isEnabled: Bool
    let plan: String?
    let refreshedAt: Date?
    let health: Health
    let primaryMetrics: [WidgetMetricContent]
    let secondaryMetrics: [WidgetMetricContent]
}

struct WidgetMetricContent: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case progress
        case value
        case status
        case chart
    }

    enum Severity: String, Hashable, Sendable {
        case neutral
        case normal
        case warning
        case critical
    }

    let id: String
    let title: String
    let kind: Kind
    let headline: String
    let detail: String?
    let progressFraction: Double?
    let resetAt: Date?
    let severity: Severity
    let hasData: Bool
}

enum WidgetDisplayState: Hashable, Sendable {
    case provider(WidgetProviderContent, isStale: Bool)
    case missingData
    case corruptData
    case unsupportedData
    case missingProvider(String)
}
