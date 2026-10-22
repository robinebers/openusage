import Foundation
import XCTest
@testable import OpenUsage

/// Real-filesystem coverage for the credential writer. Every test stays inside a unique temporary
/// directory and verifies both data integrity and the POSIX boundary that protects local secrets.
final class LocalTextFileAccessorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.LocalTextFileAccessor.\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path)
        {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testFreshCredentialFileIsOwnerReadWriteOnly() throws {
        let file = temporaryDirectory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("credentials.json")

        try LocalTextFileAccessor().writeText(file.path, #"{"token":"s3cr3t"}"#)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"token":"s3cr3t"}"#)
        XCTAssertEqual(try permissions(of: file), 0o600)
        XCTAssertEqual(try siblingNames(of: file), ["credentials.json"])
    }

    func testOverwriteTightensExistingPermissiveFile() throws {
        let file = temporaryDirectory.appendingPathComponent("api-key")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try "old-key".write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertEqual(try permissions(of: file), 0o644)

        try LocalTextFileAccessor().writeText(file.path, "new-key")

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new-key")
        XCTAssertEqual(try permissions(of: file), 0o600)
        XCTAssertEqual(try siblingNames(of: file), ["api-key"])
    }

    func testFailedReplacementRemovesPrivateTemporaryFile() throws {
        let destinationDirectory = temporaryDirectory.appendingPathComponent("credential", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try LocalTextFileAccessor().writeText(destinationDirectory.path, "secret"))

        XCTAssertEqual(try siblingNames(of: destinationDirectory), ["credential"])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testReplaceTextNeverBringsBackAMissingDirectory() throws {
        let home = temporaryDirectory.appendingPathComponent("removed-home", isDirectory: true)
        let file = home.appendingPathComponent("auth.json")

        XCTAssertThrowsError(try LocalTextFileAccessor().replaceText(file.path, #"{"token":"rotated"}"#)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOENT)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    func testExclusiveAccessWaitsForAnotherProcessHoldingTheDirectory() throws {
        // Another OpenUsage process (the CLI rotating a token) holds the home: a check-then-write
        // here must wait for it, not interleave with it.
        let home = temporaryDirectory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = ["-e", "open(my $d, '<', $ARGV[0]) or die; flock($d, 2) or die; $| = 1; print \"locked\\n\"; sleep 1.5", home.path]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { holder.waitUntilExit() }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 7), Data("locked\n".utf8))

        // The holder keeps the lock for 1.5 s after printing; entering before it exits would be instant.
        let started = Date()
        try LocalTextFileAccessor().withExclusiveAccess(toDirectoryOf: home.appendingPathComponent("auth.json").path) {}

        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.8, "did not wait for the other process")
    }

    func testAVolumeThatCannotLockADirectoryStillGetsTheWrite() throws {
        // smbfs answers EISDIR to a directory flock, an NFS mount without locking ENOTSUP: the
        // credential must still be written there (unlocked), as it was before the lock existed.
        let logDirectory = temporaryDirectory.appendingPathComponent("log", isDirectory: true)
        let sink = LogFile(directory: logDirectory, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.info)
        addTeardownBlock {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
        }
        let home = temporaryDirectory.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("auth.json").path
        try LocalTextFileAccessor().writeText(file, "old")
        for code in [EISDIR, ENOTSUP] {
            var accessor = LocalTextFileAccessor()
            accessor.lock = { _, _ in errno = code; return -1 }

            try accessor.withExclusiveAccess(toDirectoryOf: file) { try accessor.replaceText(file, "rotated-\(code)") }

            XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "rotated-\(code)")
        }

        // Any other refusal is still an error, and the body does not run.
        var refusing = LocalTextFileAccessor()
        refusing.lock = { _, _ in errno = EIO; return -1 }
        XCTAssertThrowsError(try refusing.withExclusiveAccess(toDirectoryOf: file) { XCTFail("ran unlocked") })

        // The fallback is never silent: each unlocked write leaves a warning, the refusal none.
        let log = try String(contentsOf: logDirectory.appendingPathComponent("OpenUsage.log"), encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "writing without the cross-process lock").count - 1, 2, log)
    }

    private func permissions(of file: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private func siblingNames(of file: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).sorted()
    }
}
