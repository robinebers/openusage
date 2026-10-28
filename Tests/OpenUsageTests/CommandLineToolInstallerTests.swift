import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CommandLineToolInstallerTests: XCTestCase {
    private func fixture() throws -> (root: URL, source: String, destination: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("OpenUsage.app/Contents/Helpers/openusage")
        let destination = root.appendingPathComponent("bin/openusage")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        return (root, source.path, destination.path)
    }

    func testInstallAndUninstallOwnSymlink() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { operation, source, destination in
                do {
                    switch operation {
                    case .install:
                        try FileManager.default.createDirectory(
                            atPath: (destination as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
                    case .uninstall:
                        try FileManager.default.removeItem(atPath: destination)
                    }
                    return .success
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
        )

        XCTAssertEqual(installer.status, .notInstalled)
        installer.install()
        XCTAssertEqual(installer.status, .installed)
        installer.uninstall()
        XCTAssertEqual(installer.status, .notInstalled)
    }

    func testALinkFromAnotherCopyOfOpenUsageIsReplacedOnInstall() throws {
        for other in ["Applications/OpenUsage.app", "Downloads/OpenUsage 0.7.16.app", "moved-away/OpenUsage.app"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let otherHelper = fixture.root.appendingPathComponent("\(other)/Contents/Helpers/openusage").path
            if !other.hasPrefix("moved-away") {
                try FileManager.default.createDirectory(atPath: (otherHelper as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: otherHelper))
            }
            try FileManager.default.createDirectory(atPath: (fixture.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: fixture.destination, withDestinationPath: otherHelper)
            var operations: [CommandLineToolInstaller.Operation] = []
            let installer = CommandLineToolInstaller(
                sourcePath: fixture.source,
                destinationPath: fixture.destination,
                performPrivileged: { operation, source, destination in
                    operations.append(operation)
                    do {
                        switch operation {
                        case .install(let replacing):
                            if replacing != nil { try FileManager.default.removeItem(atPath: destination) }
                            try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
                        case .uninstall:
                            try FileManager.default.removeItem(atPath: destination)
                        }
                        return .success
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }
            )

            XCTAssertEqual(installer.status, .linkedToAnotherCopy(otherHelper), other)
            installer.install()
            XCTAssertEqual(operations, [.install(replacing: otherHelper)], other)
            XCTAssertEqual(installer.status, .installed, other)
            XCTAssertNil(installer.errorMessage, other)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination), fixture.source, other)
        }
    }

    func testAFailedInstallOverAnotherCopysLinkKeepsTheStatusAndReportsTheError() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherHelper = fixture.root.appendingPathComponent("Applications/OpenUsage.app/Contents/Helpers/openusage").path
        try FileManager.default.createDirectory(atPath: (fixture.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.destination, withDestinationPath: otherHelper)
        let installer = CommandLineToolInstaller(sourcePath: fixture.source, destinationPath: fixture.destination) { _, _, _ in .failure("x") }

        installer.install()

        XCTAssertEqual(installer.status, .linkedToAnotherCopy(otherHelper), "the link did not change, so the footer must show the error, not the notice")
        XCTAssertEqual(installer.errorMessage, "Couldn't install the terminal helper: x")
    }

    func testUninstallRemovesALinkFromAnotherCopyOfOpenUsage() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let otherHelper = fixture.root.appendingPathComponent("Applications/OpenUsage.app/Contents/Helpers/openusage").path
        try FileManager.default.createDirectory(atPath: (fixture.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.destination, withDestinationPath: otherHelper)
        var operations: [CommandLineToolInstaller.Operation] = []
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { operation, _, destination in
                operations.append(operation)
                try? FileManager.default.removeItem(atPath: destination)
                return .success
            }
        )

        installer.uninstall()

        XCTAssertEqual(operations, [.uninstall(target: otherHelper)])
        XCTAssertEqual(installer.status, .notInstalled)
    }

    func testALinkIntoAnotherAppsBundleIsAConflict() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(atPath: (fixture.destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let foreign = fixture.root.appendingPathComponent("Applications/Usage.app/Contents/Helpers/openusage").path
        try FileManager.default.createSymbolicLink(atPath: fixture.destination, withDestinationPath: foreign)
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        installer.install()
        installer.uninstall()
        XCTAssertFalse(operationRan)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination), foreign)
    }

    func testTheHelperRuleNamesOnlyOpenUsageBundles() {
        XCTAssertTrue(CommandLineToolInstaller.isOpenUsageHelper("/Applications/OpenUsage.app/Contents/Helpers/openusage"))
        XCTAssertTrue(CommandLineToolInstaller.isOpenUsageHelper("/Users/me/Dev/openusage/dist/OpenUsage.app/Contents/Helpers/openusage"))
        XCTAssertTrue(CommandLineToolInstaller.isOpenUsageHelper("/Applications/OpenUsage Beta.app/Contents/Helpers/openusage"))
        XCTAssertFalse(CommandLineToolInstaller.isOpenUsageHelper("/Applications/OpenUsage.app/Contents/MacOS/openusage"))
        XCTAssertFalse(CommandLineToolInstaller.isOpenUsageHelper("/Applications/Usage.app/Contents/Helpers/openusage"))
        XCTAssertFalse(CommandLineToolInstaller.isOpenUsageHelper("/opt/homebrew/bin/openusage"))
        XCTAssertFalse(CommandLineToolInstaller.isOpenUsageHelper("Contents/Helpers/openusage"))
    }

    func testForeignPathIsNeverOverwritten() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("foreign".utf8).write(to: URL(fileURLWithPath: fixture.destination))
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        installer.install()
        XCTAssertFalse(operationRan)
        XCTAssertNotNil(installer.errorMessage)
        XCTAssertEqual(try String(contentsOfFile: fixture.destination, encoding: .utf8), "foreign")
    }

    func testForeignSymlinkIsNeverClaimedOrRemoved() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.destination,
            withDestinationPath: "/tmp/another-openusage"
        )
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        installer.uninstall()
        XCTAssertFalse(operationRan)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination),
            "/tmp/another-openusage"
        )
    }

    func testMissingHelperIsReportedWithoutAskingForAuthorization() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(atPath: fixture.source)
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        installer.install()
        XCTAssertFalse(operationRan)
        XCTAssertEqual(installer.status, .notInstalled)
        XCTAssertNotNil(installer.errorMessage)
    }
}
