import XCTest
@testable import OpenUsage

@MainActor
final class UpdaterControllerTests: XCTestCase {
    func testFinishingUpdateSessionClearsIndicator() {
        let updater = UpdaterController()
        updater.availableUpdateVersion = "0.8.1"

        updater.standardUserDriverWillFinishUpdateSession()

        XCTAssertNil(updater.availableUpdateVersion)
    }
}
