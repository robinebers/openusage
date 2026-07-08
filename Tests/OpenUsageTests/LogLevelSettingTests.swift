import XCTest
@testable import OpenUsage

/// Covers the level setting's release default reconciliation (the issue says Info, not the Tauri
/// runtime's Error), raw-value parsing, the fallback for unrecognized/dropped values (`off`/`trace`),
/// and the severity ordering the file-sink gate relies on. Hermetic per-test `UserDefaults` suites
/// keep a real persisted `logLevel` from leaking in.
final class LogLevelSettingTests: XCTestCase {
    func testDefaultIsInfoWhenUnset() {
        let defaults = makeDefaults("unset")
        XCTAssertEqual(defaults.enumValue(forKey: LogLevelSetting.key, default: LogLevelSetting.fallback), .info)
        XCTAssertEqual(LogLevelSetting.fallback, .info)
    }

    func testValidRawValuesParse() {
        for level in LogLevelSetting.allCases {
            XCTAssertEqual(LogLevelSetting(rawValue: level.rawValue), level)
        }
        // The raw values mirror the Tauri store strings.
        XCTAssertEqual(LogLevelSetting(rawValue: "error"), .error)
        XCTAssertEqual(LogLevelSetting(rawValue: "warn"), .warn)
        XCTAssertEqual(LogLevelSetting(rawValue: "info"), .info)
        XCTAssertEqual(LogLevelSetting(rawValue: "debug"), .debug)
    }

    func testUnrecognizedFallsBackToInfo() {
        let defaults = makeDefaults("unrecognized")
        for bogus in ["off", "trace", "garbage", "ERROR", ""] {
            defaults.set(bogus, forKey: LogLevelSetting.key)
            XCTAssertEqual(
                defaults.enumValue(forKey: LogLevelSetting.key, default: LogLevelSetting.fallback),
                .info,
                "raw value \(bogus) should fall back to .info"
            )
        }
    }

    func testStoredValueRoundTrips() {
        let defaults = makeDefaults("roundtrip")
        for level in LogLevelSetting.allCases {
            defaults.set(level.rawValue, forKey: LogLevelSetting.key)
            XCTAssertEqual(defaults.enumValue(forKey: LogLevelSetting.key, default: LogLevelSetting.fallback), level)
        }
    }

    func testSeverityOrdering() {
        XCTAssertLessThan(LogLevelSetting.error.severity, LogLevelSetting.warn.severity)
        XCTAssertLessThan(LogLevelSetting.warn.severity, LogLevelSetting.info.severity)
        XCTAssertLessThan(LogLevelSetting.info.severity, LogLevelSetting.debug.severity)
    }

    func testLabelsAreTitleCase() {
        XCTAssertEqual(LogLevelSetting.error.label, "Error")
        XCTAssertEqual(LogLevelSetting.warn.label, "Warning")
        XCTAssertEqual(LogLevelSetting.info.label, "Info")
        XCTAssertEqual(LogLevelSetting.debug.label, "Debug")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        makeScratchDefaults(suiteName: "OpenUsageTests.LogLevel.\(name).\(UUID().uuidString)")
    }
}
