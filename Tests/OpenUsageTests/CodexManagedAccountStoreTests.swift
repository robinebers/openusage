import XCTest
@testable import OpenUsage

/// The managed-login registry and the cache eviction a removal relies on.
@MainActor
final class CodexManagedAccountStoreTests: XCTestCase {
    private static let managedRoot = "/Users/dev/Library/Application Support/OpenUsage/codex-accounts/com.example"

    func testStoreRoundTripsLoginsAndResolvesHomesUnderItsRoot() throws {
        let defaults = makeScratchDefaults("CodexManaged")
        let root = URL(fileURLWithPath: Self.managedRoot)
        let login = CodexManagedLogin(
            id: UUID(), home: "\(Self.managedRoot)/A", identityKey: "acct-b|bob@test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), lastSignedInAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        CodexManagedAccountStore(defaults: defaults, root: root).upsert(login)

        let reloaded = CodexManagedAccountStore(defaults: defaults, root: root)
        XCTAssertFalse(reloaded.loadFailed)
        XCTAssertEqual(reloaded.logins, [login])
        XCTAssertEqual(reloaded.login(identityKey: "acct-b|bob@test")?.identity?.email, "bob@test")

        // Only the folder name is persisted: a moved home directory re-resolves under the new root.
        let blob = try XCTUnwrap(defaults.data(forKey: CodexManagedAccountStore.storageKey))
        XCTAssertFalse(String(decoding: blob, as: UTF8.self).contains(Self.managedRoot))
        let moved = CodexManagedAccountStore(defaults: defaults, root: URL(fileURLWithPath: "/Users/renamed/codex-accounts"))
        XCTAssertEqual(moved.logins.first?.home, "/Users/renamed/codex-accounts/A")

        reloaded.remove(id: login.id)
        XCTAssertTrue(CodexManagedAccountStore(defaults: defaults, root: root).logins.isEmpty)
    }

    func testAnUndecodableListIsReportedAndNeverOverwritten() {
        let defaults = makeScratchDefaults("CodexManagedCorrupt")
        let raw = Data("not json".utf8)
        defaults.set(raw, forKey: CodexManagedAccountStore.storageKey)

        let store = CodexManagedAccountStore(defaults: defaults, root: URL(fileURLWithPath: Self.managedRoot))
        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(store.logins.isEmpty)
        store.upsert(CodexManagedLogin(id: UUID(), home: "\(Self.managedRoot)/A", identityKey: "acct-b|bob@test", createdAt: Date(), lastSignedInAt: Date()))
        XCTAssertEqual(defaults.data(forKey: CodexManagedAccountStore.storageKey), raw)
    }

    func testAListOfTheWrongTypeAlsoCountsAsUnreadable() {
        let defaults = makeScratchDefaults("CodexManagedWrongType")
        defaults.set("[]", forKey: CodexManagedAccountStore.storageKey)

        let store = CodexManagedAccountStore(defaults: defaults, root: URL(fileURLWithPath: Self.managedRoot))

        XCTAssertTrue(store.loadFailed)
        XCTAssertTrue(store.logins.isEmpty)
    }

    func testAFolderThatClimbsOutOfTheRootMakesTheListUnreadable() {
        // A restored or hand-edited list could name `../../.codex` as a folder. Mapped under the
        // root, that home would pass for a managed one: never refused as a duplicate, and rotated
        // into by every refresh. Such a list pauses management like an undecodable one.
        func store(folder: String) -> CodexManagedAccountStore {
            let defaults = makeScratchDefaults("CodexManagedEscape")
            let entry = """
            [{"id":"5A2E7D7E-2C8B-4D8B-9D2D-1B2C3D4E5F60","folder":"\(folder)","identityKey":"acct-b|bob@test",\
            "createdAt":"2024-01-01T00:00:00Z","lastSignedInAt":"2024-01-01T00:00:00Z"}]
            """
            defaults.set(Data(entry.utf8), forKey: CodexManagedAccountStore.storageKey)
            return CodexManagedAccountStore(defaults: defaults, root: URL(fileURLWithPath: Self.managedRoot))
        }

        for folder in ["../../.codex", "a/b", "..", ".", ""] {
            let escaping = store(folder: folder)
            XCTAssertTrue(escaping.loadFailed, "folder \(folder) was mapped under the root")
            XCTAssertTrue(escaping.logins.isEmpty, "folder \(folder) was mapped under the root")
        }

        // Control: a plain folder name loads under the root.
        let plain = store(folder: "B")
        XCTAssertFalse(plain.loadFailed)
        XCTAssertEqual(plain.logins.first?.home, "\(Self.managedRoot)/B")
    }

    func testManagedRootIsSplitByBundleIdentifier() {
        let support = URL(fileURLWithPath: "/Users/dev/Library/Application Support")
        XCTAssertEqual(
            CodexManagedAccountStore.managedRoot(applicationSupport: support, bundleIdentifier: "com.example.dev").path,
            "/Users/dev/Library/Application Support/OpenUsage/codex-accounts/com.example.dev"
        )
        XCTAssertEqual(
            CodexManagedAccountStore.managedRoot(applicationSupport: support, bundleIdentifier: nil).lastPathComponent,
            "unbundled"
        )
    }

    func testAnAccountAwareInstallWithoutALoginNeverPaintsACachedCodexSnapshot() {
        let defaults = makeScratchDefaults("CodexManagedAwareCache")
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let snapshot = ProviderSnapshot.make(provider: CodexProvider.makeProvider(), plan: "Pro", lines: [], refreshedAt: Date())
        // A concurrent `openusage` run wrote the removed account's snapshot back without a stamp.
        cache.store(snapshot, producedByIdentityKey: nil)
        let registry = WidgetRegistry(providers: [CodexProvider.makeProvider()], descriptors: [])

        let accountAware = WidgetDataStore(
            registry: registry, providers: [], cache: cache, defaults: defaults,
            providerIdentityKeys: [:], accountAwareFamilies: ["codex"]
        )
        XCTAssertNil(accountAware.snapshots["codex"])

        // A legacy install (never account-aware) keeps its identity-less cache paint as before.
        let legacy = WidgetDataStore(registry: registry, providers: [], cache: cache, defaults: defaults)
        XCTAssertEqual(legacy.snapshots["codex"]?.plan, "Pro")
    }

    func testAnAccountAwareInstallWithNoLoginLeftRendersNoPeerHistory() {
        // The production path of the merge: iCloud hands peer files to the store. A legacy install
        // still takes the bare entry; an account-aware one with no login left must not.
        let provider = CodexProvider.makeProvider()
        let descriptors = [WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")]
            + WidgetDescriptor.spendTiles(provider: provider)
        let now = Date()
        let history = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 123, costUSD: 1),
        ]))
        let peer = UsageHistoryDocument(deviceID: "peer", deviceName: "Peer", updatedAt: now, providers: ["codex": history])
        func store(accountAware: Bool) -> WidgetDataStore {
            let defaults = makeScratchDefaults("CodexManagedAwarePeers")
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [provider], descriptors: descriptors), providers: [],
                cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults, now: { now },
                accountAwareFamilies: accountAware ? ["codex"] : []
            )
            store.setPeerHistoryDocuments([peer], ownDeviceID: "this-mac")
            return store
        }
        XCTAssertNotNil(store(accountAware: false).snapshots["codex"], "control: a legacy install takes the peer's history")
        XCTAssertNil(store(accountAware: true).snapshots["codex"], "the fallback card of an account-aware install took a peer's history")
    }

    func testRemovalForgetsEveryCardOfTheAccountThroughTheGivenCache() {
        let defaults = makeScratchDefaults("CodexManagedForget")
        let registry = ProviderAccountsStore(defaults: defaults)
        registry.reconcile(with: [.init(family: "codex", identityKey: "acct-b|bob@test", label: nil, sources: [])])
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let snapshot = ProviderSnapshot.make(provider: CodexProvider.makeProvider(), plan: nil, lines: [], refreshedAt: Date())
        cache.store(snapshot, producedByIdentityKey: "acct-b|bob@test")
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["codex"]).count, 1)

        let ids = CodexManagedAccountService.cardIDs(identityKey: "acct-b|bob@test", defaults: defaults)
        XCTAssertEqual(ids, ["codex"])
        cache.forget(providerIDs: ids)

        // Gone from the live memo and from disk, so a later write by another provider can't bring it back.
        XCTAssertTrue(cache.loadSnapshots(providerIDs: ["codex"]).isEmpty)
        XCTAssertNil(cache.producedByIdentityKey(providerID: "codex"))
        cache.store(ProviderSnapshot.make(provider: ClaudeProvider.makeProvider(), plan: nil, lines: [], refreshedAt: Date()))
        XCTAssertTrue(ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: ["codex"]).isEmpty)
    }

    func testARotatedTokenNeverBringsBackAHomeRemovedMeanwhile() throws {
        // A refresh verified the credential on disk, then Remove deleted the home before the write
        // landed. The write must fail, not recreate the folder with the rotated token in it.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-managed-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let authPath = home.appendingPathComponent("auth.json").path
        try LocalTextFileAccessor().writeText(authPath, CodexMultiAccountFixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "old"))
        let files = RemovingBeforeWrite(home: home)
        let store = scopedStore(files: files, home: home)
        let onDisk = try XCTUnwrap(store.loadAuth(at: authPath))
        var rotated = onDisk
        rotated.auth.tokens?.refreshToken = "new"

        XCTAssertThrowsError(try store.save(rotated, replacing: onDisk))

        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
    }

    func testARotationThatCheckedTheOldLoginCannotOverwriteAFreshSignIn() throws {
        // A background refresh verified the old credential and is about to write its rotation when
        // Sign In Again publishes a new login for the same account. The new login must win, however
        // the two interleave.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-managed-renewal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = home.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let authPath = home.appendingPathComponent("auth.json").path
        let fresh = CodexMultiAccountFixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "fresh")
        try LocalTextFileAccessor().writeText(authPath, CodexMultiAccountFixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "old"))
        try LocalTextFileAccessor().writeText(staging.appendingPathComponent("auth.json").path, fresh)
        let pausing = PausingReplace()
        let store = scopedStore(files: pausing, home: home)
        let onDisk = try XCTUnwrap(store.loadAuth(at: authPath))
        var rotated = onDisk
        rotated.auth.tokens?.refreshToken = "rotated-old"

        let writer = Thread { try? store.save(rotated, replacing: onDisk) }
        writer.start()
        XCTAssertEqual(pausing.checked.wait(timeout: .now() + 5), .success, "the rotation never reached its write")
        // Let the paused rotation resume shortly after the publish asks for the lock.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { pausing.resume.signal() }
        let flow = CodexManagedLoginFlow(
            launcher: FakeCodexLoginLauncher(files: FakeFiles()), files: LocalTextFileAccessor(),
            shellPATH: { nil }, processEnvironment: [:], homeDirectory: home
        )
        try flow.moveAuth(from: staging, to: home)
        XCTAssertEqual(pausing.finished.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(try String(contentsOfFile: authPath, encoding: .utf8), fresh)
    }

    func testARotationThatArrivesDuringAFreshSignInBacksOff() throws {
        // The other order: Sign In Again holds the home while it publishes, and the rotation that
        // checked the old login meanwhile must see the new one and back off with a conflict.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-managed-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = home.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let authPath = home.appendingPathComponent("auth.json").path
        let fresh = CodexMultiAccountFixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "fresh")
        try LocalTextFileAccessor().writeText(authPath, CodexMultiAccountFixtures.codexAuth(accountID: "ACCT-B", email: "bob@test", refreshToken: "old"))
        try LocalTextFileAccessor().writeText(staging.appendingPathComponent("auth.json").path, fresh)
        let store = scopedStore(files: LocalTextFileAccessor(), home: home)
        let onDisk = try XCTUnwrap(store.loadAuth(at: authPath))
        var rotated = onDisk
        rotated.auth.tokens?.refreshToken = "rotated-old"
        let pausing = PausingPublish()
        let flow = CodexManagedLoginFlow(
            launcher: FakeCodexLoginLauncher(files: FakeFiles()), files: pausing,
            shellPATH: { nil }, processEnvironment: [:], homeDirectory: home
        )

        let publisher = Thread { try? flow.moveAuth(from: staging, to: home) }
        publisher.start()
        XCTAssertEqual(pausing.entered.wait(timeout: .now() + 5), .success, "the publish never took the home")
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300)) { pausing.resume.signal() }
        XCTAssertThrowsError(try store.save(rotated, replacing: onDisk)) { error in
            XCTAssertEqual(error as? CodexAuthError, .tokenConflict)
        }

        XCTAssertEqual(try String(contentsOfFile: authPath, encoding: .utf8), fresh)
    }

    /// An auth store scoped to the fixture's account and home, so this Mac's real environment,
    /// Keychain, and any xswap registry stay out of the race: unscoped, a real xswap slot would make
    /// the synthetic credential read-only and end the rotation before the step under test.
    private func scopedStore(files: any TextFileAccessing, home: URL) -> CodexAuthStore {
        CodexAuthStore(
            environment: FakeEnvironment([:]), files: files, keychain: FakeKeychain(),
            expectedIdentity: CodexAccountIdentity(accountID: "ACCT-B", email: "bob@test"),
            writableAuthHomes: [CodexHomeScanner.canonicalHome(home.path)]
        )
    }

    /// The real accessor, except that a publish into the home pauses while holding the home's lock
    /// until the test lets it go.
    private final class PausingPublish: TextFileAccessing, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        private let disk = LocalTextFileAccessor()

        func exists(_ path: String) -> Bool { disk.exists(path) }
        func readText(_ path: String) throws -> String { try disk.readText(path) }
        func writeText(_ path: String, _ text: String) throws {
            entered.signal()
            resume.wait()
            try disk.writeText(path, text)
        }
        func withExclusiveAccess<T>(toDirectoryOf path: String, _ body: () throws -> T) throws -> T {
            try disk.withExclusiveAccess(toDirectoryOf: path, body)
        }
        func remove(_ path: String) throws { try disk.remove(path) }
    }

    /// The real accessor, except that a replacement pauses after the credential check — the
    /// moment a competing publish would land — until the test lets it go.
    private final class PausingReplace: TextFileAccessing, @unchecked Sendable {
        let checked = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        private let disk = LocalTextFileAccessor()

        func exists(_ path: String) -> Bool { disk.exists(path) }
        func readText(_ path: String) throws -> String { try disk.readText(path) }
        func writeText(_ path: String, _ text: String) throws { try disk.writeText(path, text) }
        func replaceText(_ path: String, _ text: String) throws {
            checked.signal()
            resume.wait()
            defer { finished.signal() }
            try disk.replaceText(path, text)
        }
        func withExclusiveAccess<T>(toDirectoryOf path: String, _ body: () throws -> T) throws -> T {
            try disk.withExclusiveAccess(toDirectoryOf: path, body)
        }
        func remove(_ path: String) throws { try disk.remove(path) }
    }

    /// Forwards to the real accessor, but removes the home right before the write — the window
    /// between the credential check and the atomic replacement.
    private struct RemovingBeforeWrite: TextFileAccessing {
        let home: URL
        private let disk = LocalTextFileAccessor()

        func exists(_ path: String) -> Bool { disk.exists(path) }
        func readText(_ path: String) throws -> String { try disk.readText(path) }
        func writeText(_ path: String, _ text: String) throws { try disk.writeText(path, text) }
        func replaceText(_ path: String, _ text: String) throws {
            try FileManager.default.removeItem(at: home)
            try disk.replaceText(path, text)
        }
        func remove(_ path: String) throws { try disk.remove(path) }
    }
}
