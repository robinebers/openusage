import Observation
import os
import XCTest
@testable import OpenUsage

@MainActor
final class LaunchAtLoginSettingTests: XCTestCase {
    func testFailedChangeRollsBackWithoutMakingASecondSystemCall() {
        let systemEnabled = false
        var requestedValues: [Bool] = []
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { enabled in
                requestedValues.append(enabled)
                throw TestError.rejected
            }
        )

        setting.update(to: true)

        XCTAssertEqual(requestedValues, [true])
        XCTAssertFalse(setting.isEnabled)
        XCTAssertEqual(setting.errorMessage, LaunchAtLoginSetting.failureMessage)
    }

    func testLaterSuccessUpdatesTheSwitchAndClearsTheError() {
        var systemEnabled = false
        var shouldFail = true
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { enabled in
                if shouldFail { throw TestError.rejected }
                systemEnabled = enabled
            }
        )
        setting.update(to: true)
        shouldFail = false

        setting.update(to: true)

        XCTAssertTrue(setting.isEnabled)
        XCTAssertNil(setting.errorMessage)
    }

    func testRefreshStatusReflectsExternalChangesWithoutUpdatingTheLoginItem() {
        var systemEnabled = false
        var requestedValues: [Bool] = []
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { requestedValues.append($0) }
        )

        systemEnabled = true
        setting.refreshStatus()

        XCTAssertTrue(setting.isEnabled)
        XCTAssertTrue(requestedValues.isEmpty)
    }

    func testRefreshStatusClearsStaleErrorAfterExternalChange() {
        var systemEnabled = false
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { _ in throw TestError.rejected }
        )
        setting.update(to: true)
        XCTAssertEqual(setting.errorMessage, LaunchAtLoginSetting.failureMessage)

        systemEnabled = true
        setting.refreshStatus()

        XCTAssertTrue(setting.isEnabled)
        XCTAssertNil(setting.errorMessage)
    }

    func testUnchangedRefreshDoesNotInvalidateStatusObservers() {
        let setting = LaunchAtLoginSetting(
            currentStatus: { false },
            setEnabled: { _ in XCTFail("Refreshing must not update the login item") }
        )
        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = setting.isEnabled
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        setting.refreshStatus()

        XCTAssertFalse(invalidated.withLock { $0 })
    }

    private enum TestError: Error {
        case rejected
    }
}
