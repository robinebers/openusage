import Foundation

extension Bundle {
    /// The bundle carrying OpenUsage's copied resources (provider SVGs, pricing supplement + snapshots).
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
            Bundle.main.resourceURL,                          // packaged .app: Contents/Resources
            Bundle.main.bundleURL,                            // bundle beside the app root
            containingAppResources,                          // bundled CLI: helper -> app Resources
            Bundle(for: ResourceBundleToken.self).resourceURL,
            Bundle(for: ResourceBundleToken.self).bundleURL
        ]
        for case let base? in searchBases {
            guard let bundle = Bundle(url: base.appendingPathComponent(bundleName)) else { continue }
            if isValidOpenUsageResourceBundle(bundle) {
                return bundle
            }
            // `Bundle(url:)` succeeds for ANY directory at the path, not only a real resources bundle.
            // A stale/empty same-named directory left by an earlier build would otherwise shadow the
            // real one and make every resource URL nil (SF-Symbol icon fallbacks + a thrown Cursor
            // manifest). Skip it loudly and keep searching the remaining bases.
            AppLog.warn(.config, "ignoring resource bundle at \(base.lastPathComponent): missing expected resources")
        }
        return .module
    }()
}

/// Sentinel check: a valid OpenUsage resource bundle carries the bundled pricing supplement at its
/// root (`.copy("Resources/pricing_supplement.json")`). Uses the same lookup the pricing store relies
/// on, so it can never reject the real shipped bundle.
private func isValidOpenUsageResourceBundle(_ bundle: Bundle) -> Bool {
    bundle.url(forResource: "pricing_supplement", withExtension: "json") != nil
}

private final class ResourceBundleToken {}
