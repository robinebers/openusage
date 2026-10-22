import XCTest
@testable import OpenUsage

/// The add and sign-in-again flows of Codex logins OpenUsage signs in itself, against a fake CLI.
@MainActor
final class CodexManagedAccountTests: XCTestCase {
    private typealias Fixtures = CodexMultiAccountFixtures

    func testAddAccountRunsCodexLoginInAPrivateHomeAndRecordsTheIdentity() async throws {
        let harness = try makeManagedAccountHarness()
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test")
        harness.launcher.outputChunks = ["If your browser did not open, navigate to this URL to authenticate:\n\nhttps://auth.openai.com/oauth/authorize?x=1\n"]

        harness.service.addAccount()
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.launcher.recordedArguments, ["login", "-c", "cli_auth_credentials_store=\"file\""])
        let home = try XCTUnwrap(harness.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertTrue(home.hasPrefix(harness.homes.path + "/"))
        XCTAssertTrue(harness.launcher.recordedEnvironment["PATH"]?.hasPrefix(harness.binDirectory.path) == true)
        XCTAssertEqual(harness.store.logins.map(\.identityKey), ["acct-b|bob@test"])
        XCTAssertEqual(harness.store.logins.first?.home, home)
        XCTAssertEqual(harness.reloads.count, 1, "the cards were not rebuilt")
        guard case .succeeded(let message) = harness.service.phase else { return XCTFail("expected success, got \(harness.service.phase)") }
        XCTAssertTrue(message.contains("bob@test"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home))
        let permissions = try FileManager.default.attributesOfItem(atPath: home)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
    }

    func testAddingAnAccountTheBrowserAlreadyShowsIsRefused() async throws {
        let harness = try makeManagedAccountHarness(externalIdentityKeys: ["acct-a|alice@test"])
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test")

        harness.service.addAccount()
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.alreadyShown(account: "alice@test").localizedDescription))
        XCTAssertTrue(harness.store.logins.isEmpty)
        XCTAssertEqual(harness.reloads.count, 0, "the cards were rebuilt for a change that was not made")
        let stagedHome = try XCTUnwrap(harness.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedHome))
    }

    func testALoginThatSavedNothingSaysSo() async throws {
        // The CLI exited 0 but wrote no auth.json: that is "nothing saved", not "an API key".
        let harness = try makeManagedAccountHarness()
        harness.service.addAccount()
        await waitUntilSettled(harness.service)
        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.noLogin.localizedDescription))
    }

    func testARefusedSignInNeverWritesTheEmailToTheLog() async throws {
        // The refusal names the account to the user; the log gets only its payload-free code.
        let logFile = captureLog()
        let harness = try makeManagedAccountHarness(externalIdentityKeys: ["acct-a|alice@test"])
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test")

        harness.service.addAccount()
        await waitUntilSettled(harness.service)

        let log = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("managed login failed: alreadyShown"), log)
        XCTAssertFalse(log.contains("alice@test"), "the log carries the email")
    }

    func testAFailedLoginKeepsTheCLIsErrorLineOutOfTheLog() async throws {
        // A wrapper around the CLI can fail with a line that names the account or carries a token:
        // the section shows that line, the log gets only the exit code.
        let logFile = captureLog()
        let harness = try makeManagedAccountHarness()
        harness.launcher.exitCode = 1
        harness.launcher.outputChunks = [
            "Error logging in: access denied for alice@test; refresh_token=rt_synthetic_marker see https://auth.openai.com/help\n",
        ]

        harness.service.addAccount()
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.loginFailed(
            exitCode: 1, detail: "Error logging in: access denied for alice@test; refresh_token=rt_synthetic_marker see <url>"
        ).localizedDescription))
        let log = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("managed login failed: loginFailed(exit 1)"), log)
        XCTAssertFalse(log.contains("alice@test"), "the log carries the email")
        XCTAssertFalse(log.contains("rt_synthetic_marker"), "the log carries the token")
    }

    /// Routes the app log into a temporary file at the Info level until teardown; returns the file.
    private func captureLog() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-managed-log-\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let original = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.info)
        addTeardownBlock {
            AppLog.sink = original
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("OpenUsage.log")
    }

    func testAddIsRefusedWhenThisLaunchCouldNotReadTheOtherLogins() async throws {
        // Codex discovery was skipped (login shell cold): the other logins are unknown, so a
        // duplicate could not be refused after the browser round-trip. Refuse before it instead.
        let harness = try makeManagedAccountHarness(externalIdentityKeys: nil)
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-A", email: "alice@test")

        harness.service.addAccount()
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.externalLoginsUnknown.localizedDescription))
        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertTrue(harness.store.logins.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.homes.path), [])
    }

    func testOrphanedHomesAreSweptAtStartup() throws {
        var orphan: URL?
        var kept: URL?
        let harness = try makeManagedAccountHarness { store, homes in
            orphan = homes.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            kept = homes.appendingPathComponent("kept", isDirectory: true)
            try FileManager.default.createDirectory(at: orphan!, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: kept!, withIntermediateDirectories: true)
            store.upsert(CodexManagedLogin(id: UUID(), home: kept!.path, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date()))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(orphan).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(kept).path))
        XCTAssertEqual(harness.store.logins.count, 1)
    }

    func testFailedLoginReportsTheCLIsErrorLine() async throws {
        let harness = try makeManagedAccountHarness()
        harness.launcher.exitCode = 1
        harness.launcher.outputChunks = ["Starting local login server on http://localhost:1455.\n\u{1B}[31mError logging in: Port 1455 is already in use\u{1B}[0m\n"]

        harness.service.addAccount()
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.service.phase, .failed("Codex sign-in failed: Error logging in: Port 1455 is already in use"))
    }

    func testAddingAnAlreadyManagedAccountReplacesItsCredentialInstead() async throws {
        let harness = try makeManagedAccountHarness()
        let existingHome = harness.homes.appendingPathComponent("existing").path
        harness.files.files["\(existingHome)/auth.json"] = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "old")
        let existing = CodexManagedLogin(id: UUID(), home: existingHome, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(existing)
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "new")

        harness.service.addAccount()
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.store.logins.map(\.id), [existing.id])
        XCTAssertTrue(harness.files.files["\(existingHome)/auth.json"]?.contains("\"new\"") == true)
        let stagedHome = try XCTUnwrap(harness.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedHome))
    }

    func testACancelWhileTheResultIsReadPublishesNothing() async throws {
        // The CLI finished and wrote its login; Cancel lands while that login is being read back.
        // Add must record nothing and drop its home; Sign In Again must keep the old credential.
        let add = try makeManagedAccountHarness(hookReads: true)
        add.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test")
        add.readHook.onRead = CodexManagedAccountHarness.cancelFromReader(add.service)
        add.service.addAccount()
        await waitUntilSettled(add.service)
        XCTAssertEqual(add.service.phase, .failed(CodexManagedLoginError.cancelled.localizedDescription))
        XCTAssertTrue(add.store.logins.isEmpty)
        XCTAssertEqual(add.reloads.count, 0, "the cards were rebuilt for a change that was not made")
        let stagedHome = try XCTUnwrap(add.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedHome))

        let renew = try makeManagedAccountHarness(hookReads: true)
        let home = renew.homes.appendingPathComponent("existing").path
        let old = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "old")
        renew.files.files["\(home)/auth.json"] = old
        let login = CodexManagedLogin(id: UUID(), home: home, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        renew.store.upsert(login)
        renew.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "new")
        renew.readHook.onRead = CodexManagedAccountHarness.cancelFromReader(renew.service)
        renew.service.signInAgain(login)
        await waitUntilSettled(renew.service)
        XCTAssertEqual(renew.service.phase, .failed(CodexManagedLoginError.cancelled.localizedDescription))
        XCTAssertEqual(renew.files.files["\(home)/auth.json"], old)
        XCTAssertEqual(renew.store.logins, [login])
        XCTAssertEqual(renew.reloads.count, 0, "the cards were rebuilt for a change that was not made")
        let staging = try XCTUnwrap(renew.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
    }

    func testSignInAgainRejectsAnotherAccountAndKeepsTheOldCredential() async throws {
        let harness = try makeManagedAccountHarness()
        let home = harness.homes.appendingPathComponent("existing").path
        let old = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "old")
        harness.files.files["\(home)/auth.json"] = old
        let login = CodexManagedLogin(id: UUID(), home: home, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(login)
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-C", email: "carol@test")

        harness.service.signInAgain(login)
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.identityMismatch(
            expected: "bob@test", actual: "carol@test"
        ).localizedDescription))
        XCTAssertEqual(harness.files.files["\(home)/auth.json"], old)
        XCTAssertEqual(harness.reloads.count, 0, "the cards were rebuilt for a change that was not made")

        // The same email in another workspace is another account, and the refusal must say which.
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-D", email: "bob@test")
        harness.service.signInAgain(login)
        await waitUntilSettled(harness.service)
        XCTAssertEqual(harness.service.phase, .failed(CodexManagedLoginError.identityMismatch(
            expected: "bob@test (workspace acct-b)", actual: "bob@test (workspace acct-d)"
        ).localizedDescription))
        XCTAssertEqual(harness.files.files["\(home)/auth.json"], old)
        let staging = try XCTUnwrap(harness.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging))
    }

    func testSignInAgainWithTheSameAccountReplacesTheCredentialInPlace() async throws {
        let harness = try makeManagedAccountHarness()
        let home = harness.homes.appendingPathComponent("existing").path
        harness.files.files["\(home)/auth.json"] = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "old")
        let login = CodexManagedLogin(id: UUID(), home: home, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(login)
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "new")

        harness.service.signInAgain(login)
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.reloads.count, 1, "the cards were not rebuilt")
        XCTAssertTrue(harness.files.files["\(home)/auth.json"]?.contains("\"new\"") == true)
        XCTAssertEqual(harness.store.logins.first?.lastSignedInAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testFailuresSurfaceFriendlyMessages() async throws {
        // "Codex not installed" is covered by the locator tests in CodexLoginLauncherTests: the
        // service also searches the usual install prefixes, so a test can't make this Mac look
        // Codex-free.
        let apiKeyOnly = try makeManagedAccountHarness()
        apiKeyOnly.launcher.authText = #"{"OPENAI_API_KEY":"sk-test"}"#
        apiKeyOnly.service.addAccount()
        await waitUntilSettled(apiKeyOnly.service)
        XCTAssertEqual(apiKeyOnly.service.phase, .failed(CodexManagedLoginError.apiKeyOnly.localizedDescription))
        XCTAssertTrue(apiKeyOnly.store.logins.isEmpty)

        let failed = try makeManagedAccountHarness()
        failed.launcher.exitCode = 1
        failed.service.addAccount()
        await waitUntilSettled(failed.service)
        XCTAssertEqual(failed.service.phase, .failed(CodexManagedLoginError.loginFailed(exitCode: 1, detail: nil).localizedDescription))
        let stagedHome = try XCTUnwrap(failed.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedHome))

        // A `codex` the locator accepts but the system can't start (a wrapper whose interpreter is
        // gone): the user sees the system's reason, not an opaque error code.
        let unstartable = try makeManagedAccountHarness()
        unstartable.launcher.spawnErrno = ENOENT
        unstartable.service.addAccount()
        await waitUntilSettled(unstartable.service)
        XCTAssertEqual(
            unstartable.service.phase,
            .failed("Couldn't start Codex (No such file or directory). Check the Codex CLI installation, then try again.")
        )
        let unstartedHome = try XCTUnwrap(unstartable.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unstartedHome))
    }

    func testASuccessfulChangeRebuildsTheCardsBeforeTheOutcomeShows() async throws {
        // The rebuild runs with the change already saved, under a busy section, and only then does
        // the outcome show; a failure never asks for a rebuild.
        let harness = try makeManagedAccountHarness()
        harness.reloads.holds = true
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test")

        harness.service.addAccount()
        for _ in 0..<200 where harness.reloads.count == 0 { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertEqual(harness.reloads.count, 1)
        XCTAssertEqual(harness.store.logins.map(\.identityKey), ["acct-b|bob@test"], "the rebuild ran before the login was saved")
        XCTAssertEqual(harness.service.phase, .applying)
        XCTAssertTrue(harness.service.isBusy)
        harness.reloads.release()
        await waitUntilSettled(harness.service)
        XCTAssertEqual(harness.service.phase, .succeeded("Signed in as bob@test."))
    }

    func testNamesCarryTheWorkspaceOnlyWhenAnotherLoginSharesTheEmail() async throws {
        // bob@test is already managed in one workspace; the same email in another workspace is a
        // second account, and both the outcome and a removal must say which one.
        let harness = try makeManagedAccountHarness()
        let existingHome = harness.homes.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingHome, withIntermediateDirectories: true)
        let existing = CodexManagedLogin(id: UUID(), home: existingHome.path, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(existing)
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-D", email: "bob@test")

        harness.service.addAccount()
        await waitUntilSettled(harness.service)
        XCTAssertEqual(harness.service.phase, .succeeded("Signed in as bob@test (workspace acct-d)."))

        harness.service.dismissMessage()
        harness.service.remove(existing)
        await waitUntilSettled(harness.service)
        XCTAssertEqual(harness.service.phase, .succeeded("Removed bob@test (workspace acct-b)."))
        XCTAssertEqual(harness.reloads.count, 2)
    }

    func testSignInAgainRecreatesAMissingHomeAsPrivate() async throws {
        let harness = try makeManagedAccountHarness()
        let home = harness.homes.appendingPathComponent("gone").path
        let login = CodexManagedLogin(id: UUID(), home: home, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(login)
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test")

        harness.service.signInAgain(login)
        await waitUntilSettled(harness.service)

        XCTAssertEqual(harness.reloads.count, 1, "the cards were not rebuilt")
        let permissions = try FileManager.default.attributesOfItem(atPath: home)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
    }

    func testASecondRequestWhileSigningInIsIgnored() async throws {
        let harness = try makeManagedAccountHarness()
        harness.launcher.holds = true
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test")
        let other = CodexManagedLogin(id: UUID(), home: harness.homes.appendingPathComponent("other").path, identityKey: "acct-c|carol@test", createdAt: Date(), lastSignedInAt: Date())
        harness.store.upsert(other)

        harness.service.addAccount()
        for _ in 0..<100 where harness.launcher.launchCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(harness.service.isBusy)
        harness.service.addAccount()
        harness.service.signInAgain(other)
        harness.service.remove(other)
        XCTAssertTrue(harness.service.isBusy)
        XCTAssertEqual(harness.service.phase, .signingIn(loginID: nil, url: nil))
        XCTAssertEqual(harness.store.logins.map(\.id), [other.id])

        harness.launcher.release()
        await waitUntilSettled(harness.service)
        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.store.logins.map(\.identityKey), ["acct-c|carol@test", "acct-b|bob@test"])
    }

    func testFailedCredentialPublishLeavesNoOrphanHome() async throws {
        let harness = try makeManagedAccountHarness(readOnlyAuthWrites: true)
        let existingHome = harness.homes.appendingPathComponent("existing").path
        let old = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "old")
        harness.files.files["\(existingHome)/auth.json"] = old
        harness.store.upsert(CodexManagedLogin(id: UUID(), home: existingHome, identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date()))
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "new")

        harness.service.addAccount()
        await waitUntilSettled(harness.service)

        guard case .failed = harness.service.phase else { return XCTFail("expected a failure, got \(harness.service.phase)") }
        XCTAssertEqual(harness.files.files["\(existingHome)/auth.json"], old)
        let stagedHome = try XCTUnwrap(harness.launcher.recordedEnvironment["CODEX_HOME"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedHome))
        XCTAssertEqual(harness.reloads.count, 0, "the cards were rebuilt for a change that was not made")
    }

    func testSignInURLIsReportedOnlyOnceComplete() async throws {
        let harness = try makeManagedAccountHarness()
        harness.launcher.holds = true
        harness.launcher.authText = Fixtures.codexAuth(accountID: "ACCT-B", email: "bob@test")
        harness.launcher.outputChunks = [
            "navigate to this URL to authenticate:\n\n\u{1B}[94mhttps://auth.openai.com/oauth/authorize?client_id=part",
            "two&state=abc\u{1B}[0m\n",
        ]

        harness.service.addAccount()
        for _ in 0..<200 {
            if case .signingIn(_, let url) = harness.service.phase, url != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(harness.service.phase, .signingIn(loginID: nil, url: "https://auth.openai.com/oauth/authorize?client_id=parttwo&state=abc"))

        harness.launcher.release()
        await waitUntilSettled(harness.service)
    }
}
