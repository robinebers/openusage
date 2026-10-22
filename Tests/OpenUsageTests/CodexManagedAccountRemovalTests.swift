import XCTest
@testable import OpenUsage

/// Remove and registry-repair flows of Codex logins OpenUsage signs in itself.
@MainActor
final class CodexManagedAccountRemovalTests: XCTestCase {
    func testAFirstLaunchWithoutAnyManagedFolderReportsNothing() throws {
        // No account was ever added, so the managed root does not exist yet: that is not a failure.
        let harness = try makeManagedAccountHarness { _, homes in try FileManager.default.removeItem(at: homes) }
        XCTAssertEqual(harness.service.phase, .idle)
    }

    func testAFailedStartupSweepIsReportedInsteadOfSwallowed() throws {
        // The managed root cannot be listed: nothing is swept, and the section says so at launch.
        var deniedRoot: String?
        let unlistable = try makeManagedAccountHarness { _, homes in
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: homes.path)
            deniedRoot = homes.path
        }
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: deniedRoot!) }
        guard case .failed(let message) = unlistable.service.phase else {
            return XCTFail("expected a reported sweep failure, got \(unlistable.service.phase)")
        }
        XCTAssertTrue(message.contains("couldn't check its Codex account folders"), message)

        // An orphan that cannot be deleted stays, and its credential is not reported as removed.
        var stubborn: URL?
        let undeletable = try makeManagedAccountHarness { _, homes in
            let orphan = homes.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try "{}".write(to: orphan.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: orphan.path)
            stubborn = orphan
        }
        let orphan = try XCTUnwrap(stubborn)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: orphan.path) }
        XCTAssertEqual(undeletable.service.phase, .failed("OpenUsage couldn't remove 1 leftover Codex sign-in folder. Check the log for details."))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: orphan.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.appendingPathComponent("auth.json").path))
    }

    func testRemoveDeletesOnlyHomesUnderTheManagedRoot() async throws {
        let harness = try makeManagedAccountHarness()
        let owned = harness.homes.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let ownedLogin = CodexManagedLogin(id: UUID(), home: owned.path, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        let foreign = CodexManagedLogin(id: UUID(), home: "/Users/dev/.codex", identityKey: "acct-a|alice@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(ownedLogin)
        harness.store.upsert(foreign)

        harness.service.remove(foreign)
        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.unsafeHome.localizedDescription))
        XCTAssertEqual(harness.store.logins.count, 2)

        harness.service.remove(ownedLogin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(harness.store.logins.map(\.id), [foreign.id])
        XCTAssertEqual(harness.forgotten.providerIDs, ["card:acct-b|bob@test"])
        XCTAssertEqual(harness.service.phase, .applying)
        XCTAssertTrue(harness.service.isBusy)
        await waitUntilSettled(harness.service)
        XCTAssertEqual(harness.reloads.count, 1, "the cards were not rebuilt")
        XCTAssertEqual(harness.reloads.phaseDuringReload, .applying)
        XCTAssertEqual(harness.service.phase, .succeeded("Removed bob@test."))
    }

    func testRemoveKeepsTheRecordWhenTheFolderCannotBeDeleted() throws {
        // The folder can be inspected but not deleted (its login is immutable): Remove must say so
        // and keep the record, not report "removed" while the credential stays on disk.
        let harness = try makeManagedAccountHarness()
        let owned = harness.homes.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let authPath = owned.appendingPathComponent("auth.json").path
        try "{}".write(toFile: authPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: authPath)
        addTeardownBlock { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: authPath) }
        let login = CodexManagedLogin(id: UUID(), home: owned.path, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(login)

        harness.service.remove(login)

        guard case .failed = harness.service.phase else { return XCTFail("expected a failure, got \(harness.service.phase)") }
        XCTAssertEqual(harness.store.logins, [login])
        XCTAssertTrue(harness.forgotten.providerIDs.isEmpty)
        XCTAssertEqual(harness.reloads.count, 0, "the cards were rebuilt for a change that was not made")
        XCTAssertTrue(FileManager.default.fileExists(atPath: authPath))
    }

    func testRemoveKeepsTheRecordWhenTheFolderCannotBeReached() async throws {
        // The managed root lost its permissions: the folder can neither be inspected nor deleted.
        // That is a failure to show, not an "already gone" — the credential is still on disk.
        let harness = try makeManagedAccountHarness()
        let owned = harness.homes.appendingPathComponent("owned", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let authPath = owned.appendingPathComponent("auth.json").path
        try "{}".write(toFile: authPath, atomically: true, encoding: .utf8)
        let login = CodexManagedLogin(id: UUID(), home: owned.path, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(login)
        let homes = harness.homes.path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: homes)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homes) }

        harness.service.remove(login)

        guard case .failed = harness.service.phase else { return XCTFail("expected a failure, got \(harness.service.phase)") }
        XCTAssertEqual(harness.store.logins, [login])
        XCTAssertTrue(harness.forgotten.providerIDs.isEmpty)
        XCTAssertEqual(harness.reloads.count, 0, "the cards were rebuilt for a change that was not made")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: homes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: authPath))

        // A folder that is genuinely gone is the one case Remove may treat as already done.
        try FileManager.default.removeItem(at: owned)
        harness.service.remove(login)
        await waitUntilSettled(harness.service)
        XCTAssertTrue(harness.store.logins.isEmpty)
        XCTAssertEqual(harness.forgotten.providerIDs, ["card:acct-b|bob@test"])
        XCTAssertEqual(harness.reloads.count, 1, "the cards were not rebuilt")
    }

    func testAnUnreadableRegistryPausesManagementAndKeepsEveryHome() async throws {
        var stray: URL?
        let harness = try makeManagedAccountHarness(corruptRegistry: true) { _, homes in
            stray = homes.appendingPathComponent("not-in-the-list", isDirectory: true)
            try FileManager.default.createDirectory(at: stray!, withIntermediateDirectories: true)
        }
        XCTAssertTrue(harness.store.loadFailed)
        // Said at launch: the accounts in the broken list are off the dashboard until it is repaired.
        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.registryUnreadable.localizedDescription))
        // No sweep: the folder may belong to a record the list would have named.
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(stray).path))

        harness.service.addAccount()
        await waitUntilSettled(harness.service)
        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.registryUnreadable.localizedDescription))
        XCTAssertEqual(harness.launcher.launchCount, 0)

        let login = CodexManagedLogin(id: UUID(), home: try XCTUnwrap(stray).path, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        harness.service.remove(login)
        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.registryUnreadable.localizedDescription))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(stray).path))
        // That the raw list is left alone for repair is CodexManagedAccountStoreTests' job.
    }

    func testRemoveRefusesAHomeReachedThroughASymlinkOrNestedPath() throws {
        let harness = try makeManagedAccountHarness()
        let outside = harness.root.appendingPathComponent("outside", isDirectory: true)
        let victim = outside.appendingPathComponent("account", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        let bridge = harness.homes.appendingPathComponent("bridge")
        try FileManager.default.createSymbolicLink(at: bridge, withDestinationURL: outside)
        let nested = CodexManagedLogin(id: UUID(), home: bridge.appendingPathComponent("account").path, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        let linked = CodexManagedLogin(id: UUID(), home: bridge.path, identityKey: "acct-c|carol@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(nested)
        harness.store.upsert(linked)

        harness.service.remove(nested)
        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.unsafeHome.localizedDescription))
        harness.service.remove(linked)
        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.unsafeHome.localizedDescription))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertEqual(harness.store.logins.count, 2)
    }
}
