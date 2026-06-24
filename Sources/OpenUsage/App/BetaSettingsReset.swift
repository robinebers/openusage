import Foundation

/// Beta policy: every time the app's version changes between beta builds, wipe all persisted settings so
/// each beta starts from a clean slate. During the beta program we deliberately ship **no migrations** —
/// rather than carry a previous beta's layout/preferences forward (and risk a half-migrated state), an
/// upgrade resets everything to defaults, exactly like a fresh install.
///
/// Gated on the *current* build being a pre-release (its version carries a `-` suffix, e.g.
/// `0.7.0-beta.13`): a plain stable version never triggers an automatic wipe, so the eventual public
/// release won't reset users out from under themselves — that transition is handled deliberately.
///
/// Must run once at launch **before any store reads `UserDefaults`**, so the wipe is clean (nothing is
/// cached yet) and the stores that follow re-seed their fresh-install defaults. Every OpenUsage setting
/// lives in the app's standard `UserDefaults` domain, so removing that domain clears the layout,
/// every `@AppStorage` preference, the menu-bar pins, the panel size, and the global shortcut together —
/// the genuine fresh-install state.
enum BetaSettingsReset {
    /// Where the last-run version is recorded. Re-written immediately after a wipe, so it survives the
    /// reset and the next launch at the same version is a no-op.
    static let lastRunVersionKey = "openusage.settings.lastRunVersion"

    /// Wipe all persisted settings whenever the recorded version differs from this build's version, so
    /// every beta-to-beta update is a clean slate. Returns whether a reset was performed (for logging
    /// and tests).
    ///
    /// "No recorded version" counts as a difference, deliberately: it covers both a genuinely fresh
    /// install (where the wipe is a harmless no-op on an empty domain) and an upgrade from a beta that
    /// predates this key — e.g. `0.7.0-beta.12`, which never recorded a version and must still reset.
    /// A stable (non-pre-release) build records the version without ever wiping.
    @discardableResult
    static func resetIfVersionChanged(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? "",
        version: String = AppInfo.version
    ) -> Bool {
        let stored = defaults.string(forKey: lastRunVersionKey)
        guard stored != version else { return false }

        // Any version difference on a pre-release build wipes; a stable build never auto-wipes (no
        // surprise resets in production). The empty-domain guard keeps unpackaged `swift run` (no bundle
        // id) from attempting a wipe with no domain to target.
        let shouldReset = version.contains("-") && !domainName.isEmpty
        if shouldReset {
            AppLog.info(.config, "settings reset for beta \(version) (previous run: \(stored ?? "none"))")
            defaults.removePersistentDomain(forName: domainName)
        }
        // Written last so it persists through the wipe and seeds the comparison for the next launch.
        defaults.set(version, forKey: lastRunVersionKey)
        return shouldReset
    }
}
