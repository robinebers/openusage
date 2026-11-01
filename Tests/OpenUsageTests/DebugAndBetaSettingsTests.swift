import XCTest
@testable import OpenUsage

@MainActor
final class DebugAndBetaSettingsTests: XCTestCase {
    func testLogLevelReadsTheChoiceSavedByZeroSevenSixteen() {
        restoringStandardDefault("logLevel") {
            UserDefaults.standard.removeObject(forKey: "logLevel")
            XCTAssertEqual(LogLevelSetting.current, .info)

            UserDefaults.standard.set("warn", forKey: "logLevel")
            XCTAssertEqual(LogLevelSetting.current, .warn)

            UserDefaults.standard.set("debug", forKey: "logLevel")
            XCTAssertEqual(LogLevelSetting.current, .debug)
        }
    }

    func testALogLevelKeepsOnlyLinesAtLeastAsSevere() {
        XCTAssertTrue(LogLevelSetting.info.includes(.warn))
        XCTAssertFalse(LogLevelSetting.info.includes(.debug))
        XCTAssertTrue(LogLevelSetting.debug.includes(.debug))
        XCTAssertFalse(LogLevelSetting.error.includes(.warn))
    }

    func testBetaUpdatesReadsTheChoiceSavedByZeroSevenSixteen() {
        restoringStandardDefault("betaUpdatesEnabled") {
            UserDefaults.standard.removeObject(forKey: "betaUpdatesEnabled")
            XCTAssertFalse(UpdaterController().betaChannelEnabled)

            UserDefaults.standard.set(true, forKey: "betaUpdatesEnabled")
            XCTAssertTrue(UpdaterController().betaChannelEnabled)
        }
    }

    private func restoringStandardDefault(_ key: String, _ body: () -> Void) {
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        body()
    }
}
