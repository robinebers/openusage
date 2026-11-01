import XCTest
@testable import OpenUsage

final class LogLevelSettingTests: XCTestCase {
    func testLogLevelReadsTheChoiceSavedByZeroSevenSixteen() {
        let saved = UserDefaults.standard.object(forKey: "logLevel")
        defer { UserDefaults.standard.set(saved, forKey: "logLevel") }

        UserDefaults.standard.removeObject(forKey: "logLevel")
        XCTAssertEqual(LogLevelSetting.current, .info)

        UserDefaults.standard.set("warn", forKey: "logLevel")
        XCTAssertEqual(LogLevelSetting.current, .warn)

        UserDefaults.standard.set("debug", forKey: "logLevel")
        XCTAssertEqual(LogLevelSetting.current, .debug)
    }

    func testALogLevelKeepsOnlyLinesAtLeastAsSevere() {
        XCTAssertTrue(LogLevelSetting.info.includes(.warn))
        XCTAssertFalse(LogLevelSetting.info.includes(.debug))
        XCTAssertTrue(LogLevelSetting.debug.includes(.debug))
        XCTAssertFalse(LogLevelSetting.error.includes(.warn))
    }
}
