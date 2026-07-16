import Foundation

public struct WidgetBridgeDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let providers: [WidgetProviderRecord]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date,
        providers: [WidgetProviderRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.providers = providers
    }

    /// Content that affects rendering. `generatedAt` is deliberately excluded so a clock tick alone
    /// never causes a disk write or consumes a WidgetKit reload budget.
    public var semanticContent: SemanticContent {
        SemanticContent(schemaVersion: schemaVersion, providers: providers)
    }

    public struct SemanticContent: Hashable, Sendable {
        public let schemaVersion: Int
        public let providers: [WidgetProviderRecord]
    }
}

public struct WidgetProviderRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let isEnabled: Bool
    public let plan: String?
    public let refreshedAt: Date?
    public let health: WidgetProviderHealth
    public let primaryMetrics: [WidgetMetricRecord]
    public let secondaryMetrics: [WidgetMetricRecord]

    public init(
        id: String,
        displayName: String,
        isEnabled: Bool,
        plan: String?,
        refreshedAt: Date?,
        health: WidgetProviderHealth,
        primaryMetrics: [WidgetMetricRecord],
        secondaryMetrics: [WidgetMetricRecord]
    ) {
        self.id = id
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.plan = plan
        self.refreshedAt = refreshedAt
        self.health = health
        self.primaryMetrics = primaryMetrics
        self.secondaryMetrics = secondaryMetrics
    }
}

public enum WidgetProviderHealth: String, Codable, Hashable, Sendable {
    case ready
    case warning
    case failed
    case noData
}

public struct WidgetMetricRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: WidgetMetricKind
    public let headline: String
    public let detail: String?
    public let progressFraction: Double?
    public let resetAt: Date?
    public let severity: WidgetMetricSeverity
    public let hasData: Bool

    public init(
        id: String,
        title: String,
        kind: WidgetMetricKind,
        headline: String,
        detail: String?,
        progressFraction: Double?,
        resetAt: Date?,
        severity: WidgetMetricSeverity,
        hasData: Bool
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.headline = headline
        self.detail = detail
        self.progressFraction = progressFraction
        self.resetAt = resetAt
        self.severity = severity
        self.hasData = hasData
    }
}

public enum WidgetMetricKind: String, Codable, Hashable, Sendable {
    case progress
    case value
    case status
}

public enum WidgetMetricSeverity: String, Codable, Hashable, Sendable {
    case neutral
    case normal
    case warning
    case critical
}
