import Foundation

/// Single source of truth for the app's version, shown in the dashboard footer and the About panel.
/// `CFBundleShortVersionString` carries the full version including any pre-release suffix
/// (e.g. `0.8.0-beta.2`), baked into the bundle by `script/release.sh` from the release tag; it is the
/// same string Sparkle shows in its update prompt. `script/build_and_run.sh` stamps the dev build with
/// its commit instead (`dev (abc1234)`). The fallback covers runs outside the packaged app (e.g.
/// `swift run`, where there is no Info.plist).
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
