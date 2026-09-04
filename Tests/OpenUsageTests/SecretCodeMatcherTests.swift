import XCTest
@testable import OpenUsage

final class SecretCodeMatcherTests: XCTestCase {
    private let code = SecretCodeMatcher.sequence

    func testCompletesOnFinalTokenOnly() {
        var matcher = SecretCodeMatcher()
        for token in code.dropLast() {
            XCTAssertFalse(matcher.accept(token), "should not match before the final token")
        }
        XCTAssertTrue(matcher.accept(code.last!), "the final token completes the sequence")
    }

    func testCleanEntryMatchesAfterStrayOrIncorrectPrefix() {
        let prefixes: [[SecretCodeKey]] = [[.up, .up], [.up, .up, .down, .left]]
        for prefix in prefixes {
            var matcher = SecretCodeMatcher()
            var matched = false
            for token in prefix + code { matched = matcher.accept(token) }
            XCTAssertTrue(matched)
        }
    }

    func testResetClearsPartialProgress() {
        var matcher = SecretCodeMatcher()
        _ = matcher.accept(.up)
        _ = matcher.accept(.up)
        matcher.reset()
        // After reset the tail alone must not complete — progress was cleared.
        var matched = false
        for token in code.dropFirst(2) { matched = matcher.accept(token) || matched }
        XCTAssertFalse(matched)
        // A fresh full entry still matches.
        matched = false
        for token in code { matched = matcher.accept(token) }
        XCTAssertTrue(matched)
    }

    func testReentryMatchesAgain() {
        var matcher = SecretCodeMatcher()
        for token in code { _ = matcher.accept(token) }
        // The buffer clears after a match, so a second full entry matches again (re-type to toggle off).
        var matched = false
        for token in code { matched = matcher.accept(token) }
        XCTAssertTrue(matched)
    }
}
