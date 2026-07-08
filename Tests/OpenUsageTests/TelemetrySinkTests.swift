import XCTest
@testable import OpenUsage

/// Pins the crash-reporting opt-out contract: PostHog error autocapture must be gated on the SAME
/// `enabled` flag as usage telemetry, so the privacy toggle is the single source of truth and an
/// opted-out launch installs no crash handler. Tests the pure gating decision so it never touches the
/// `PostHogSDK.shared` singleton (which would also trip the local Sparkle.framework dlopen issue).
final class TelemetrySinkTests: XCTestCase {
    func testErrorAutocaptureFollowsTheOptOut() {
        XCTAssertTrue(
            PostHogTelemetrySink.errorAutocaptureEnabled(telemetryEnabled: true),
            "crash autocapture must be on when telemetry is enabled"
        )
        XCTAssertFalse(
            PostHogTelemetrySink.errorAutocaptureEnabled(telemetryEnabled: false),
            "crash autocapture must be off when the user has opted out of telemetry"
        )
    }
}
