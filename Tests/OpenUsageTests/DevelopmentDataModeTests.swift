#if OPENUSAGE_DEVELOPMENT
import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class DevelopmentDataModeTests: XCTestCase {
    private let appDirectory = URL(fileURLWithPath: "/private/tmp/openusage-dev-fixture/dist", isDirectory: true)

    func testSwitchingToSampleDataOpensTheDemoBeforeTerminatingTheCurrentApp() async {
        let held = HeldResponse()
        var launches: [URL] = []
        var terminations = 0
        let mode = DevelopmentDataMode(
            bundleIdentifier: DevelopmentDataMode.normalBundleID,
            bundleURL: appDirectory.appendingPathComponent("OpenUsage.app", isDirectory: true),
            identifierOfBundle: { _ in DevelopmentDataMode.demoBundleID },
            openApplication: { url in
                launches.append(url)
                await held.hold()
            },
            terminate: { terminations += 1 }
        )

        XCTAssertTrue(mode.isAvailable)
        XCTAssertFalse(mode.isOn)
        let pending = Task { await mode.switchToSampleData(true) }
        await held.waitUntilHeld()

        XCTAssertTrue(mode.isSwitching)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first, appDirectory.appendingPathComponent("OpenUsage Demo.app", isDirectory: true))
        XCTAssertEqual(terminations, 0, "the current app must survive until its replacement opens")

        await held.release()
        await pending.value
        XCTAssertEqual(terminations, 1)
        XCTAssertFalse(mode.isSwitching)
        XCTAssertFalse(mode.isOn, "the source identity stays normal until the replacement app takes over")
        XCTAssertNil(mode.errorMessage)
    }

    func testSwitchingOffReturnsToTheNormalDevelopmentAppWithoutADemoArgument() async {
        var launches: [URL] = []
        var terminations = 0
        let mode = DevelopmentDataMode(
            bundleIdentifier: DevelopmentDataMode.demoBundleID,
            bundleURL: appDirectory.appendingPathComponent("OpenUsage Demo.app", isDirectory: true),
            identifierOfBundle: { _ in DevelopmentDataMode.normalBundleID },
            openApplication: { launches.append($0) },
            terminate: { terminations += 1 }
        )

        XCTAssertTrue(mode.isOn)
        await mode.switchToSampleData(false)

        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first, appDirectory.appendingPathComponent("OpenUsage.app", isDirectory: true))
        XCTAssertEqual(terminations, 1)
        XCTAssertNil(mode.errorMessage)
    }

    func testAMissingOrWrongDestinationKeepsTheSourceAppOpen() async {
        for destinationID in [nil, "com.robinebers.openusage", DevelopmentDataMode.normalBundleID] as [String?] {
            var launches = 0
            var terminations = 0
            let mode = DevelopmentDataMode(
                bundleIdentifier: DevelopmentDataMode.normalBundleID,
                bundleURL: appDirectory.appendingPathComponent("OpenUsage.app", isDirectory: true),
                identifierOfBundle: { _ in destinationID },
                openApplication: { _ in launches += 1 },
                terminate: { terminations += 1 }
            )

            await mode.switchToSampleData(true)

            XCTAssertEqual(launches, 0, "the destination identifier must be checked before launch")
            XCTAssertEqual(terminations, 0)
            XCTAssertFalse(mode.isSwitching)
            XCTAssertNotNil(mode.errorMessage)
        }
    }

    func testAFailedLaunchKeepsTheSourceAppOpenAndShowsAnError() async {
        var launches = 0
        var terminations = 0
        let mode = DevelopmentDataMode(
            bundleIdentifier: DevelopmentDataMode.normalBundleID,
            bundleURL: appDirectory.appendingPathComponent("OpenUsage.app", isDirectory: true),
            identifierOfBundle: { _ in DevelopmentDataMode.demoBundleID },
            openApplication: { _ in
                launches += 1
                throw LaunchFailure.refused
            },
            terminate: { terminations += 1 }
        )

        await mode.switchToSampleData(true)

        XCTAssertEqual(launches, 1)
        XCTAssertEqual(terminations, 0)
        XCTAssertFalse(mode.isSwitching)
        XCTAssertFalse(mode.isOn)
        XCTAssertNotNil(mode.errorMessage)
    }

    func testProductionAndUnknownAppIdentitiesCannotStartTheDemo() async {
        for sourceID in [nil, "com.robinebers.openusage", "org.example.other"] as [String?] {
            var launches = 0
            var terminations = 0
            let mode = DevelopmentDataMode(
                bundleIdentifier: sourceID,
                bundleURL: appDirectory.appendingPathComponent("OpenUsage.app", isDirectory: true),
                identifierOfBundle: { _ in DevelopmentDataMode.demoBundleID },
                openApplication: { _ in launches += 1 },
                terminate: { terminations += 1 }
            )

            XCTAssertFalse(mode.isAvailable)
            await mode.switchToSampleData(true)

            XCTAssertEqual(launches, 0)
            XCTAssertEqual(terminations, 0)
            XCTAssertFalse(mode.isSwitching)
            XCTAssertNotNil(mode.errorMessage)
        }
    }

    func testASecondRequestCannotStartAnotherLaunchWhileTheFirstIsPending() async {
        let held = HeldResponse()
        var launches = 0
        var terminations = 0
        let mode = DevelopmentDataMode(
            bundleIdentifier: DevelopmentDataMode.normalBundleID,
            bundleURL: appDirectory.appendingPathComponent("OpenUsage.app", isDirectory: true),
            identifierOfBundle: { _ in DevelopmentDataMode.demoBundleID },
            openApplication: { _ in
                launches += 1
                await held.hold()
            },
            terminate: { terminations += 1 }
        )

        let first = Task { await mode.switchToSampleData(true) }
        await held.waitUntilHeld()
        await mode.switchToSampleData(true)
        await mode.switchToSampleData(false)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(terminations, 0)

        await held.release()
        await first.value
        XCTAssertEqual(terminations, 1)
    }

    func testRequestsForTheCurrentModeDoNothing() async {
        for (sourceID, enabled) in [(DevelopmentDataMode.normalBundleID, false), (DevelopmentDataMode.demoBundleID, true)] {
            var launches = 0
            var terminations = 0
            let mode = DevelopmentDataMode(
                bundleIdentifier: sourceID,
                bundleURL: appDirectory.appendingPathComponent("OpenUsage.app", isDirectory: true),
                identifierOfBundle: { _ in nil },
                openApplication: { _ in launches += 1 },
                terminate: { terminations += 1 }
            )

            await mode.switchToSampleData(enabled)

            XCTAssertEqual(launches, 0)
            XCTAssertEqual(terminations, 0)
            XCTAssertNil(mode.errorMessage)
        }
    }

    func testTheSettingsBindingStartsTheValidatedSwitch() async throws {
        var launches = 0
        var terminations = 0
        let mode = DevelopmentDataMode(
            bundleIdentifier: DevelopmentDataMode.normalBundleID,
            bundleURL: appDirectory.appendingPathComponent("OpenUsage.app", isDirectory: true),
            identifierOfBundle: { _ in DevelopmentDataMode.demoBundleID },
            openApplication: { _ in launches += 1 },
            terminate: { terminations += 1 }
        )

        mode.setSampleData(true)
        try await waitUntil { terminations == 1 }

        XCTAssertEqual(launches, 1)
        XCTAssertNil(mode.errorMessage)
    }

    private enum LaunchFailure: Error {
        case refused
    }
}
#endif
