import Foundation

extension Bundle {
    /// The bundle carrying OpenUsage's copied provider icons.
    ///
    /// SwiftPM generates `Bundle.module` for an executable target that only looks two places: next to
    /// `Bundle.main.bundleURL` (which, for a packaged `.app`, is the app root) and a path into the build
    /// tree baked in at compile time. Neither resolves in a shipped `.app`, where the resource bundle
    /// lives in `Contents/Resources` — so `Bundle.module` hits its `fatalError` and the app crashes on
    /// launch. (A locally built app appears to work only because the baked-in build path still exists on
    /// the build machine.)
    ///
    /// This accessor looks where the resource bundle actually ships first, and only falls back to
    /// `Bundle.module` for `swift run` / `swift test`, where the build path is valid.
    static let openUsageResources: Bundle = {
        let bundleName = "OpenUsage_OpenUsage.bundle"
        let containingAppResources = Bundle.main.executableURL
            .flatMap(ContainingAppBundle.url(for:))?
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        let searchBases: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            containingAppResources,
            Bundle(for: ResourceBundleToken.self).resourceURL,
            Bundle(for: ResourceBundleToken.self).bundleURL
        ]
        for case let base? in searchBases {
            guard let bundle = Bundle(url: base.appendingPathComponent(bundleName)) else { continue }
            if bundle.url(forResource: "openusage", withExtension: "svg", subdirectory: "ProviderIcons") != nil {
                return bundle
            }
            AppLog.warn(.config, "ignoring resource bundle at \(base.lastPathComponent): missing provider icons")
        }
        return .module
    }()
}

private final class ResourceBundleToken {}
