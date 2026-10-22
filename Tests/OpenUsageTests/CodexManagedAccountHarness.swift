import XCTest
@testable import OpenUsage

/// Shared fixtures of the managed Codex account tests: a fake CLI, file doubles, and a service wired
/// to a temporary managed root with a stub `codex` on its PATH.
final class FakeCodexLoginLauncher: CodexLoginLaunching, @unchecked Sendable {
    var authText: String?
    var exitCode: Int32 = 0
    /// When set, the login fails to start with this `errno`, the way a broken wrapper script does.
    var spawnErrno: Int32?
    /// Delivered as separate chunks, the way a pipe hands them over.
    var outputChunks: [String] = []
    /// When set, each login parks here until `release()`; models a CLI waiting on the browser.
    var holds = false
    let files: FakeFiles
    /// What the logins recorded, read by the test on the main actor while a login may still be
    /// running on another executor — hence behind the lock.
    var recordedEnvironment: [String: String] { lock.lock(); defer { lock.unlock() }; return recorded.environment }
    var recordedArguments: [String] { lock.lock(); defer { lock.unlock() }; return recorded.arguments }
    var launchCount: Int { lock.lock(); defer { lock.unlock() }; return recorded.launchCount }
    private var recorded = (environment: [String: String](), arguments: [String](), launchCount: 0)
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    /// A release that arrives before the login parks is remembered, never lost.
    private var released = false

    init(files: FakeFiles) { self.files = files }

    func release() {
        lock.lock()
        released = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func runLogin(
        executable: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        lock.withLock { recorded = (environment, arguments, recorded.launchCount + 1) }
        if let spawnErrno { throw CodexLoginLaunchError.spawnFailed(errno: spawnErrno) }
        for chunk in outputChunks { onOutput(chunk) }
        if holds {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    released = false
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
        if let authText, let home = environment["CODEX_HOME"] {
            files.files["\(home)/auth.json"] = authText
        }
        return exitCode
    }
}

/// Runs `onRead` from the reader's thread before the login's `auth.json` is read back — the moment
/// a Cancel can land after the CLI already finished.
final class ReadHookFiles: TextFileAccessing, @unchecked Sendable {
    let backing: FakeFiles
    var onRead: @Sendable () -> Void = {}
    init(_ backing: FakeFiles) { self.backing = backing }
    func exists(_ path: String) -> Bool { backing.exists(path) }
    func readTextIfPresent(_ path: String) throws -> String? {
        onRead()
        return try backing.readTextIfPresent(path)
    }
    func readText(_ path: String) throws -> String { try backing.readText(path) }
    func writeText(_ path: String, _ text: String) throws { try backing.writeText(path, text) }
    func remove(_ path: String) throws { try backing.remove(path) }
}

/// A file accessor whose writes fail, for the "credential could not be published" paths.
final class ReadOnlyFiles: TextFileAccessing, @unchecked Sendable {
    let backing: FakeFiles
    init(_ backing: FakeFiles) { self.backing = backing }
    func exists(_ path: String) -> Bool { backing.exists(path) }
    func readText(_ path: String) throws -> String { try backing.readText(path) }
    func writeText(_ path: String, _ text: String) throws { throw POSIXError(.EACCES) }
    func remove(_ path: String) throws { try backing.remove(path) }
}

@MainActor
final class ForgottenSnapshots {
    var providerIDs: [String] = []
}

/// Stands in for the app's Codex card rebuild: counts the rebuilds a change asked for, and can
/// park each one until the test lets it finish.
@MainActor
final class ReloadRecorder {
    var count = 0
    /// The phase the service showed while the rebuild ran, captured by the rebuild itself.
    var phaseDuringReload: CodexManagedAccountService.Phase?
    var holds = false
    private var continuation: CheckedContinuation<Void, Never>?

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func reload(_ service: CodexManagedAccountService) async {
        count += 1
        phaseDuringReload = service.phase
        guard holds else { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

struct CodexManagedAccountHarness {
    let service: CodexManagedAccountService
    let store: CodexManagedAccountStore
    let launcher: FakeCodexLoginLauncher
    let files: FakeFiles
    let root: URL
    /// The managed root the service owns: `root/homes`.
    let homes: URL
    let binDirectory: URL
    let forgotten: ForgottenSnapshots
    let reloads: ReloadRecorder
    let readHook: ReadHookFiles

    /// Cancels `service` from whichever thread the login's result is being read on.
    static func cancelFromReader(_ service: CodexManagedAccountService) -> @Sendable () -> Void {
        {
            if Thread.isMainThread {
                MainActor.assumeIsolated { service.cancel() }
            } else {
                DispatchQueue.main.sync { MainActor.assumeIsolated { service.cancel() } }
            }
        }
    }
}

extension XCTestCase {
    @MainActor
    func makeManagedAccountHarness(
        readOnlyAuthWrites: Bool = false, hookReads: Bool = false, externalIdentityKeys: Set<String>? = [],
        corruptRegistry: Bool = false,
        prepare: (CodexManagedAccountStore, URL) throws -> Void = { _, _ in }
    ) throws -> CodexManagedAccountHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-managed-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let homes = root.appendingPathComponent("homes", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homes, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = FakeFiles()
        let launcher = FakeCodexLoginLauncher(files: files)
        let defaults = makeScratchDefaults("CodexManagedService")
        if corruptRegistry { defaults.set(Data("not json".utf8), forKey: CodexManagedAccountStore.storageKey) }
        let store = CodexManagedAccountStore(defaults: defaults, root: homes)
        try prepare(store, homes)
        let forgotten = ForgottenSnapshots()
        let readHook = ReadHookFiles(files)
        let serviceFiles: any TextFileAccessing
        if readOnlyAuthWrites {
            serviceFiles = ReadOnlyFiles(files)
        } else if hookReads {
            serviceFiles = readHook
        } else {
            serviceFiles = files
        }
        let service = CodexManagedAccountService(
            store: store, externalIdentityKeys: externalIdentityKeys,
            forgetSnapshots: { forgotten.providerIDs.append(contentsOf: $0) },
            accountCardIDs: { ["card:\($0)"] },
            launcher: launcher,
            files: serviceFiles,
            shellPATH: { bin.path }, processEnvironment: ["PATH": "/usr/bin"],
            homeDirectory: CodexMultiAccountFixtures.home, now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let reloads = ReloadRecorder()
        service.onAccountsChanged = { [weak service] in
            guard let service else { return }
            await reloads.reload(service)
        }
        return CodexManagedAccountHarness(
            service: service, store: store, launcher: launcher, files: files, root: root, homes: homes,
            binDirectory: bin, forgotten: forgotten, reloads: reloads, readHook: readHook
        )
    }

    @MainActor
    func waitUntilSettled(_ service: CodexManagedAccountService) async {
        for _ in 0..<200 {
            if !service.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("sign-in never settled")
    }
}
