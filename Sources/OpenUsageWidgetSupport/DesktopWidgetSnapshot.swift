import Foundation

/// The presentation-ready, credential-free payload passed from OpenUsage to its WidgetKit extension.
///
/// The extension deliberately receives finished labels and meter state instead of provider snapshots:
/// it never needs provider credentials, pricing data, account metadata, or app-internal model logic.
public struct DesktopWidgetSnapshot: Codable, Equatable, Sendable {
    public var updatedAt: Date?
    public var metrics: [DesktopWidgetMetric]
    public var isRedacted: Bool

    public init(updatedAt: Date?, metrics: [DesktopWidgetMetric], isRedacted: Bool = false) {
        self.updatedAt = updatedAt
        self.metrics = metrics
        self.isRedacted = isRedacted
    }

    public static let empty = DesktopWidgetSnapshot(updatedAt: nil, metrics: [])
}

public struct DesktopWidgetMetric: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case neutral
        case normal
        case warning
        case critical
    }

    public var id: String
    public var providerName: String
    public var title: String
    public var value: String
    public var subtitle: String?
    public var progress: Double?
    public var status: Status

    public init(
        id: String,
        providerName: String,
        title: String,
        value: String,
        subtitle: String?,
        progress: Double?,
        status: Status
    ) {
        self.id = id
        self.providerName = providerName
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.progress = progress
        self.status = status
    }
}

/// The stable WidgetKit kind shared by the app's reload requests and the extension configuration.
public enum DesktopUsageWidgetKind {
    public static let value = "com.robinebers.openusage.usage"
}

/// URL used when a desktop widget is clicked. Development builds use their own scheme so a locally
/// staged widget never opens an installed production copy of OpenUsage.
public enum DesktopWidgetDeepLink {
    public static func dashboardURL(bundleIdentifier: String?) -> URL {
        let isDevelopment = bundleIdentifier?.split(separator: ".").contains("dev") == true
        let scheme = isDevelopment ? "openusage-dev" : "openusage"
        return URL(string: "\(scheme)://dashboard")!
    }

    public static func isDashboardURL(_ url: URL) -> Bool {
        (url.scheme == "openusage" || url.scheme == "openusage-dev") && url.host == "dashboard"
    }
}
