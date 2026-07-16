import Foundation
import OpenUsageWidgetSupport
import os

enum WidgetBridgeReadStatus: Sendable {
    case loaded
    case missing
    case corrupt
    case unsupported
}

struct WidgetBridgeReadResult: Sendable {
    let status: WidgetBridgeReadStatus
    let document: WidgetPresentationDocument?
}

struct WidgetPresentationDocument: Sendable {
    let providers: [WidgetProviderContent]
}

enum WidgetBridgeReader {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.robinebers.openusage.widgets",
        category: "widget-bridge"
    )

    static func load() -> WidgetBridgeReadResult {
        guard
            let identifier = Bundle.main.object(
                forInfoDictionaryKey: "OpenUsageAppGroupIdentifier"
            ) as? String,
            !identifier.isEmpty,
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: identifier
            )
        else {
            logger.error("App Group configuration or container is unavailable")
            return WidgetBridgeReadResult(status: .missing, document: nil)
        }

        do {
            guard let document = try WidgetBridgeFileStore(
                appGroupContainerURL: containerURL
            ).read() else {
                return WidgetBridgeReadResult(status: .missing, document: nil)
            }
            return WidgetBridgeReadResult(
                status: .loaded,
                document: WidgetPresentationDocument(
                    providers: document.providers.map(WidgetProviderContent.init)
                )
            )
        } catch WidgetBridgeFileError.unsupportedSchema(let version) {
            logger.error("Unsupported widget bridge schema: \(version)")
            return WidgetBridgeReadResult(status: .unsupported, document: nil)
        } catch {
            logger.error("Widget bridge read failed: \(error.localizedDescription, privacy: .public)")
            return WidgetBridgeReadResult(status: .corrupt, document: nil)
        }
    }

    static func enabledProviderIDs() -> Set<String> {
        let result = load()
        guard case .loaded = result.status else { return [] }
        return Set(result.document?.providers.filter(\.isEnabled).map(\.id) ?? [])
    }
}

private extension WidgetProviderContent {
    init(_ record: WidgetProviderRecord) {
        self.init(
            id: record.id,
            displayName: record.displayName,
            isEnabled: record.isEnabled,
            plan: record.plan,
            refreshedAt: record.refreshedAt,
            health: Health(rawValue: record.health.rawValue) ?? .noData,
            primaryMetrics: record.primaryMetrics.map(WidgetMetricContent.init),
            secondaryMetrics: record.secondaryMetrics.map(WidgetMetricContent.init)
        )
    }
}

private extension WidgetMetricContent {
    init(_ record: WidgetMetricRecord) {
        self.init(
            id: record.id,
            title: record.title,
            kind: Kind(rawValue: record.kind.rawValue) ?? .status,
            headline: record.headline,
            detail: record.detail,
            progressFraction: record.progressFraction,
            resetAt: record.resetAt,
            severity: Severity(rawValue: record.severity.rawValue) ?? .neutral,
            hasData: record.hasData
        )
    }
}
