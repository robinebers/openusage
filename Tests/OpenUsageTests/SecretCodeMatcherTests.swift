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

    func testExtraLeadingKeysStillMatch() {
        var matcher = SecretCodeMatcher()
        // Two stray ups before a clean entry: the sliding window keeps only the last N, so it matches.
        let stream: [SecretCodeKey] = [.up, .up] + code
        var matched = false
        for token in stream { matched = matcher.accept(token) }
        XCTAssertTrue(matched)
    }

    func testWrongKeyMidSequenceThenCleanEntryMatches() {
        var matcher = SecretCodeMatcher()
        _ = matcher.accept(.up)
        _ = matcher.accept(.up)
        _ = matcher.accept(.down)
        _ = matcher.accept(.left) // wrong (expected .down) — run broken
        var matched = false
        for token in code { matched = matcher.accept(token) }
        XCTAssertTrue(matched, "a clean entry after a fumble still matches")
    }

    func testNoMatchForIncompleteSequence() {
        var matcher = SecretCodeMatcher()
        var matched = false
        for token in code.dropLast() { matched = matcher.accept(token) || matched }
        XCTAssertFalse(matched)
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
