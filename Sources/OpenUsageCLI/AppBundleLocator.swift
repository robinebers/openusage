import Foundation
import OpenUsage

struct AppBundleLocator: Sendable {
    let bundleIdentifier: String
    let version: String?

    static func locate(
        executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppBundleLocator {
        if let suite = environment["OPENUSAGE_DEFAULTS_SUITE"], !suite.isEmpty {
            return AppBundleLocator(bundleIdentifier: suite, version: nil)
        }

        if let appURL = ContainingAppBundle.url(for: executableURL),
           let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
           let bundleIdentifier = info["CFBundleIdentifier"] as? String {
            return AppBundleLocator(
                bundleIdentifier: bundleIdentifier,
                version: info["CFBundleShortVersionString"] as? String
            )
        }

        return AppBundleLocator(bundleIdentifier: "com.robinebers.openusage", version: nil)
    }
}
