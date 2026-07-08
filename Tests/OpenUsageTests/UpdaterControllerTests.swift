import AppKit
import XCTest
@testable import OpenUsage

@MainActor
final class UpdaterUserDriverDelegateTests: XCTestCase {
    func testFinishingUpdateSessionClearsInAppUpdateIndicator() {
        let application = NSApplication.shared
        let originalPolicy = application.activationPolicy()
        defer { application.setActivationPolicy(originalPolicy) }

        let delegate = UpdaterUserDriverDelegate()
        var resolved = false
        delegate.onUpdateResolved = { resolved = true }

        delegate.standardUserDriverWillFinishUpdateSession()

        XCTAssertTrue(resolved)
    }
}
