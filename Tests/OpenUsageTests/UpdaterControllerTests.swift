import AppKit
import XCTest
@testable import OpenUsage

@MainActor
final class UpdaterPresentationControllerTests: XCTestCase {
    func testBringToFrontUsesReliableActivationAfterChangingPolicy() {
        var policy = NSApplication.ActivationPolicy.accessory
        var active = false
        var events: [String] = []
        let presentationController = UpdaterPresentationController(
            activationPolicy: { policy },
            isActive: { active },
            setActivationPolicy: { newPolicy in
                events.append("policy:\(newPolicy.rawValue)")
                policy = newPolicy
                return true
            },
            activate: { ignoringOtherApps in
                events.append("activate:\(ignoringOtherApps)")
                active = true
            }
        )

        presentationController.bringToFront(reason: "test")

        XCTAssertEqual(policy, .regular)
        XCTAssertTrue(active)
        XCTAssertEqual(events, ["policy:\(NSApplication.ActivationPolicy.regular.rawValue)", "activate:true"])
    }

    func testReturnToMenuBarRestoresAccessoryPolicy() {
        var policy = NSApplication.ActivationPolicy.regular
        let presentationController = UpdaterPresentationController(
            activationPolicy: { policy },
            isActive: { true },
            setActivationPolicy: { newPolicy in
                policy = newPolicy
                return true
            },
            activate: { _ in XCTFail("Finishing must not reactivate the app") }
        )

        presentationController.returnToMenuBar()

        XCTAssertEqual(policy, .accessory)
    }
}

@MainActor
final class UpdaterUserDriverDelegateTests: XCTestCase {
    func testFinishingUpdateSessionRestoresPresentationAndClearsIndicator() {
        let delegate = UpdaterUserDriverDelegate()
        var sessionFinished = false
        var resolved = false
        delegate.onUpdateSessionFinished = { sessionFinished = true }
        delegate.onUpdateResolved = { resolved = true }

        delegate.standardUserDriverWillFinishUpdateSession()

        XCTAssertTrue(sessionFinished)
        XCTAssertTrue(resolved)
    }
}
