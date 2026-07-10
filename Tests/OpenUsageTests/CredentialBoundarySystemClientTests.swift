import XCTest
@testable import OpenUsage

final class CredentialBoundarySystemClientTests: XCTestCase {
    func testReadTextIfPresentReturnsNilForMissingFile() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.missing.\(UUID().uuidString)")
            .path

        XCTAssertNil(try LocalTextFileAccessor().readTextIfPresent(path))
    }

    func testRemoveTreatsOnlyMissingFileAsSuccess() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.missing.\(UUID().uuidString)")
            .path

        XCTAssertNoThrow(try LocalTextFileAccessor().remove(path))
    }

    func testSQLiteQueryDoesNotLaunchProcessForMissingDatabase() throws {
        let runner = CountingProcessRunner()
        let accessor = SQLiteCLIAccessor(processRunner: runner)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.missing.\(UUID().uuidString).sqlite")
            .path

        XCTAssertNil(try accessor.queryValue(path: path, sql: "SELECT value FROM ItemTable LIMIT 1"))
        XCTAssertEqual(runner.callCount, 0, "a local credential probe must not create/open a missing database")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testSQLiteQueryOpensExistingDatabaseReadOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.existing.\(UUID().uuidString).sqlite")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = CountingProcessRunner()
        let accessor = SQLiteCLIAccessor(processRunner: runner)

        XCTAssertNil(try accessor.queryValue(path: url.path, sql: "SELECT value FROM ItemTable LIMIT 1"))
        XCTAssertEqual(runner.callCount, 1)
        XCTAssertTrue(runner.lastArguments.contains("-readonly"))
    }
}

private final class CountingProcessRunner: ProcessRunning, @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var lastArguments: [String] = []

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        callCount += 1
        lastArguments = arguments
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
