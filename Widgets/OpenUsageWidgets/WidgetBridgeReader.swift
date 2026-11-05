import Foundation
import OpenUsageWidgetSupport
import os

struct WidgetBridgeReadResult: Sendable {
    let status: WidgetBridgeReadStatus
    let document: WidgetBridgeDocument?
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
            return WidgetBridgeReadResult(status: .loaded, document: document)
        } catch WidgetBridgeFileError.unsupportedSchema(let version) {
            logger.error("Unsupported widget bridge schema: \(version)")
            return WidgetBridgeReadResult(status: .unsupported, document: nil)
        } catch {
            logger.error("Widget bridge read failed: \(error.localizedDescription, privacy: .public)")
            return WidgetBridgeReadResult(status: .corrupt, document: nil)
        }
    }
}
