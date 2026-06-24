import XCTest
@testable import OpenUsage

final class BetaSettingsResetTests: XCTestCase {
    /// No recorded version on a beta build still wipes: this is the `0.7.0-beta.12 → beta.13` upgrade,
    /// where the previous beta never recorded a version. Settings left behind must be cleared (a
    /// genuinely fresh install hits the same path, where the wipe is a harmless no-op on an empty domain).
    func testNoRecordedVersionWipesOnBeta() {
        let (defaults, domain) = makeDefaults("NoRecordedVersion")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("stale-layout", forKey: "openusage.layout.v1")

        let didReset = BetaSettingsReset.resetIfVersionChanged(
            defaults: defaults, domainName: domain, version: "0.7.0-beta.13"
        )

        XCTAssertTrue(didReset)
        XCTAssertNil(defaults.string(forKey: "openusage.layout.v1"))
        XCTAssertEqual(defaults.string(forKey: BetaSettingsReset.lastRunVersionKey), "0.7.0-beta.13")
    }

    /// A version change between two betas wipes every persisted setting and records the new version.
    func testBetaVersionChangeWipesAllSettings() {
        let (defaults, domain) = makeDefaults("BetaChange")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("0.7.0-beta.12", forKey: BetaSettingsReset.lastRunVersionKey)
        defaults.set("custom-layout", forKey: "openusage.layout.v1")
        defaults.set("dark", forKey: "appearance")
        defaults.set(720.0, forKey: "openusage.panelHeight")

        let didReset = BetaSettingsReset.resetIfVersionChanged(
            defaults: defaults, domainName: domain, version: "0.7.0-beta.13"
        )

        XCTAssertTrue(didReset)
        XCTAssertNil(defaults.string(forKey: "openusage.layout.v1"))
        XCTAssertNil(defaults.string(forKey: "appearance"))
        XCTAssertNil(defaults.object(forKey: "openusage.panelHeight"))
        XCTAssertEqual(defaults.string(forKey: BetaSettingsReset.lastRunVersionKey), "0.7.0-beta.13")
    }

    /// Relaunching the same beta build preserves everything — only a version *change* resets.
    func testSameVersionPreservesSettings() {
        let (defaults, domain) = makeDefaults("SameVersion")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("0.7.0-beta.13", forKey: BetaSettingsReset.lastRunVersionKey)
        defaults.set("custom-layout", forKey: "openusage.layout.v1")

        let didReset = BetaSettingsReset.resetIfVersionChanged(
            defaults: defaults, domainName: domain, version: "0.7.0-beta.13"
        )

        XCTAssertFalse(didReset)
        XCTAssertEqual(defaults.string(forKey: "openusage.layout.v1"), "custom-layout")
    }

    /// A stable (non-pre-release) build never auto-wipes, so the eventual public release does not reset
    /// users out from under themselves. The version is still recorded.
    func testStableVersionChangeDoesNotWipe() {
        let (defaults, domain) = makeDefaults("StableChange")
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("0.7.0-beta.13", forKey: BetaSettingsReset.lastRunVersionKey)
        defaults.set("custom-layout", forKey: "openusage.layout.v1")

        let didReset = BetaSettingsReset.resetIfVersionChanged(
            defaults: defaults, domainName: domain, version: "0.7.0"
        )

        XCTAssertFalse(didReset)
        XCTAssertEqual(defaults.string(forKey: "openusage.layout.v1"), "custom-layout")
        XCTAssertEqual(defaults.string(forKey: BetaSettingsReset.lastRunVersionKey), "0.7.0")
    }

    private func makeDefaults(_ name: String) -> (UserDefaults, String) {
        let suiteName = "OpenUsageTests.BetaSettingsReset.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
