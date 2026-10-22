import Foundation
import Observation

enum CodexManagedLoginError: Error, LocalizedError, Equatable {
    case codexNotInstalled
    case cancelled
    case timedOut
    /// `detail` is the CLI's own last error line, when it printed one.
    case loginFailed(exitCode: Int32, detail: String?)
    /// The CLI exited 0 but wrote no login into the managed home.
    case noLogin
    /// The home holds an API key instead of a ChatGPT login, which cannot read subscription usage.
    case apiKeyOnly
    case incompleteIdentity
    /// The browser signed in as an account OpenUsage already shows from another login.
    case alreadyShown(account: String)
    /// Sign In Again produced a different account than the one being renewed.
    case identityMismatch(expected: String, actual: String)
    case unsafeHome
    case registryUnreadable
    /// This launch could not read the other Codex logins on the Mac (login shell cold).
    case externalLoginsUnknown

    var errorDescription: String? {
        switch self {
        case .codexNotInstalled:
            return "Codex CLI not found. Install Codex, then try again."
        case .cancelled:
            return "Sign-in cancelled."
        case .timedOut:
            return "Sign-in timed out. Try again."
        case .loginFailed(let exitCode, let detail):
            if let detail { return "Codex sign-in failed: \(detail)" }
            return "Codex sign-in failed (exit \(exitCode)). Try again."
        case .noLogin:
            return "Codex finished without saving a login. Try again."
        case .apiKeyOnly:
            return "Codex saved an API key instead of a ChatGPT login. Sign in with your ChatGPT account."
        case .incompleteIdentity:
            return "Codex signed in, but the login names no workspace or email, so OpenUsage can't keep it apart from other accounts."
        case .alreadyShown(let account):
            return "Your browser signed in as \(account), which OpenUsage already shows. Sign out of ChatGPT in the browser, or open the sign-in link in a private window, then try again."
        case .identityMismatch(let expected, let actual):
            return "Your browser signed in as \(actual), but this entry is \(expected). Sign out of ChatGPT in the browser, or open the sign-in link in a private window, then try again."
        case .unsafeHome:
            return "This account's folder is not one OpenUsage created, so it was left alone."
        case .registryUnreadable:
            return "OpenUsage couldn't read its list of Codex accounts, so nothing was changed, and the accounts added here stay off the dashboard until it is repaired. Check the log for details."
        case .externalLoginsUnknown:
            return "OpenUsage couldn't check your other Codex logins because it couldn't read your shell settings at this launch. Relaunch OpenUsage, then add the account."
        }
    }

    /// A stable, payload-free name for the log: the payloads carry emails.
    var logCode: String {
        switch self {
        case .codexNotInstalled: "codexNotInstalled"
        case .cancelled: "cancelled"
        case .timedOut: "timedOut"
        case .loginFailed(let exitCode, _): "loginFailed(exit \(exitCode))"
        case .noLogin: "noLogin"
        case .apiKeyOnly: "apiKeyOnly"
        case .incompleteIdentity: "incompleteIdentity"
        case .alreadyShown: "alreadyShown"
        case .identityMismatch: "identityMismatch"
        case .unsafeHome: "unsafeHome"
        case .registryUnreadable: "registryUnreadable"
        case .externalLoginsUnknown: "externalLoginsUnknown"
        }
    }
}

/// Signs Codex accounts in and out of private homes OpenUsage owns, and keeps the UI's view of that
/// work. Every successful change is handed to `onAccountsChanged` (the app rebuilds its Codex cards
/// in place) before the outcome is shown. One operation runs at a time; a second request while one
/// is in flight is ignored (the UI disables its buttons), never allowed to disturb the first.
@MainActor
@Observable
final class CodexManagedAccountService {
    enum Phase: Equatable {
        case idle
        /// `url` is the sign-in page once the CLI printed it, for a browser that did not open.
        case signingIn(loginID: UUID?, url: String?)
        /// The change is saved; the dashboard's Codex cards are being rebuilt for it.
        case applying
        case succeeded(String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    let store: CodexManagedAccountStore
    /// Rebuilds the app's Codex cards for the saved change; awaited before the outcome is published.
    @ObservationIgnored var onAccountsChanged: @MainActor () async -> Void = {}

    private let flow: CodexManagedLoginFlow
    private let root: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    /// `nil` when this launch skipped Codex discovery (login shell cold, no snapshot yet): the other
    /// logins on this Mac are unknown, so Add cannot tell a new account from one already shown.
    private var externalIdentityKeys: Set<String>?
    private let forgetSnapshots: @MainActor (_ providerIDs: [String]) -> Void
    private let accountCardIDs: @MainActor (_ identityKey: String) -> [String]
    /// The operation whose outcome may still change `phase`; a stale task's result is dropped.
    @ObservationIgnored private var currentOperation: UUID?
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    /// `forgetSnapshots` must reach the app's live snapshot cache (`WidgetDataStore`): a fresh cache
    /// instance would clear the disk only for the live memo to write the removed card back.
    init(
        store: CodexManagedAccountStore,
        externalIdentityKeys: Set<String>?,
        forgetSnapshots: @escaping @MainActor (_ providerIDs: [String]) -> Void,
        accountCardIDs: @escaping @MainActor (_ identityKey: String) -> [String] = {
            CodexManagedAccountService.cardIDs(identityKey: $0)
        },
        launcher: any CodexLoginLaunching = SystemCodexLoginLauncher(),
        files: any TextFileAccessing = LocalTextFileAccessor(),
        fileManager: FileManager = .default,
        shellPATH: @escaping @Sendable () -> String? = { LoginShellEnvironment.shared.value(for: "PATH") },
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.root = store.root
        self.fileManager = fileManager
        self.now = now
        self.externalIdentityKeys = externalIdentityKeys
        self.forgetSnapshots = forgetSnapshots
        self.accountCardIDs = accountCardIDs
        self.flow = CodexManagedLoginFlow(
            launcher: launcher, files: files, shellPATH: shellPATH,
            processEnvironment: processEnvironment, homeDirectory: homeDirectory
        )
        if store.loadFailed {
            // The accounts in the broken list are hidden from the dashboard until it is repaired;
            // say so here instead of leaving an empty first-run section.
            phase = .failed(CodexManagedLoginError.registryUnreadable.localizedDescription)
        } else {
            sweepOrphanHomes()
        }
    }

    var logins: [CodexManagedLogin] { store.logins }

    var isBusy: Bool { operationTask != nil }

    /// The other Codex logins as the latest account pass found them (see `externalIdentityKeys`).
    func updateExternalLogins(_ identityKeys: Set<String>?) {
        externalIdentityKeys = identityKeys
    }

    /// Signs a new account into a fresh managed home. A login that turns out to be an account already
    /// managed here replaces that record's credentials instead of adding a duplicate; one OpenUsage
    /// already shows from a Codex, xswap, or pi login is refused (the browser picked the wrong account).
    func addAccount() {
        start(loginID: nil) { [self] in
            // Decided before the browser opens: without the other logins, a duplicate of an account
            // already on the dashboard could not be refused afterwards.
            guard let externalIdentityKeys else { throw CodexManagedLoginError.externalLoginsUnknown }
            let home = try makeHome()
            var keepHome = false
            defer { if !keepHome { removeHomeBestEffort(home) } }
            let identity = try await flow.signIn(home: home, onURL: urlReporter())
            // Back on the main actor, where Cancel runs: a cancel that landed while the login's
            // result was being read must not be followed by a publish.
            try Task.checkCancellation()
            if let existing = store.login(identityKey: identity.key) {
                try flow.moveAuth(from: home, to: try ensureOwnedHome(of: existing))
                var updated = existing
                updated.lastSignedInAt = now()
                store.upsert(updated)
                AppLog.info(LogTag.auth("codex"), "managed login renewed through Add")
                return "Signed in again as \(name(of: identity))."
            }
            if externalIdentityKeys.contains(identity.key) {
                throw CodexManagedLoginError.alreadyShown(account: name(of: identity))
            }
            store.upsert(CodexManagedLogin(
                id: UUID(), home: home.path, identityKey: identity.key,
                createdAt: now(), lastSignedInAt: now()
            ))
            keepHome = true
            AppLog.info(LogTag.auth("codex"), "managed login added")
            return "Signed in as \(name(of: identity))."
        }
    }

    /// Signs the same account in again, keeping its home (and session history). The browser session
    /// must belong to that account; anything else is rejected and the old credentials stay.
    func signInAgain(_ login: CodexManagedLogin) {
        start(loginID: login.id) { [self] in
            // Fail before the browser round-trip when the record points somewhere OpenUsage won't write.
            _ = try ownedHome(of: login)
            let staging = try makeHome(prefix: "staging-")
            defer { removeHomeBestEffort(staging) }
            let identity = try await flow.signIn(home: staging, onURL: urlReporter())
            try Task.checkCancellation()
            guard identity.key == login.identityKey else {
                throw CodexManagedLoginError.identityMismatch(
                    expected: login.identity.map { name(of: $0, besides: [identity]) } ?? login.identityKey,
                    actual: name(of: identity, besides: login.identity.map { [$0] } ?? [])
                )
            }
            try flow.moveAuth(from: staging, to: try ensureOwnedHome(of: login))
            var updated = login
            updated.lastSignedInAt = now()
            store.upsert(updated)
            AppLog.info(LogTag.auth("codex"), "managed login renewed")
            return "Signed in again as \(name(of: identity))."
        }
    }

    /// Deletes the managed home and forgets the login, then rebuilds the cards without it. Never
    /// touches logins outside the managed root.
    func remove(_ login: CodexManagedLogin) {
        guard !isBusy else { return }
        guard !store.loadFailed else {
            phase = .failed(CodexManagedLoginError.registryUnreadable.localizedDescription)
            return
        }
        do {
            let home = try ownedHome(of: login)
            // Delete, and accept only "already gone" as done: a folder that can be inspected but not
            // deleted (a locked file inside, a parent without write permission) must keep its
            // record, or its credential outlives the list.
            do {
                try fileManager.removeItem(at: home)
            } catch let error where Self.isMissingFile(error) {}
        } catch let error as CodexManagedLoginError {
            phase = .failed(error.localizedDescription)
            AppLog.error(LogTag.auth("codex"), "refused to remove a managed Codex home: \(error.logCode)")
            return
        } catch {
            phase = .failed("Couldn't remove the account's folder: \(error.localizedDescription)")
            AppLog.error(LogTag.auth("codex"), "failed to remove a managed Codex home: \(error.localizedDescription)")
            return
        }
        let account = login.identity.map { name(of: $0) } ?? login.identityKey
        store.remove(id: login.id)
        // The removed account may have been the one on the bare `codex` card. Rebuilt without a
        // login, that card comes back plain and identity-less, and would then adopt this account's
        // cached numbers as its own; its snapshot goes now, before the rebuild can read it.
        forgetSnapshots(accountCardIDs(login.identityKey))
        AppLog.info(LogTag.auth("codex"), "managed login removed")
        apply(outcome: "Removed \(account).")
    }

    func cancel() {
        operationTask?.cancel()
    }

    func dismissMessage() {
        guard !isBusy else { return }
        phase = .idle
    }

    /// Every Codex card id the account registry holds for `identityKey`. Read fresh: the registry is
    /// written by the account pass and the service never holds the app's live instance.
    static func cardIDs(identityKey: String, defaults: UserDefaults = .standard) -> [String] {
        ProviderAccountsStore(defaults: defaults).records
            .filter { $0.family == "codex" && $0.identityKey == identityKey }
            .map(\.id)
    }

    /// The email, as the section's rows name accounts. Two workspaces of one email are two
    /// accounts, so when any known login — managed, external, or one named alongside — shares the
    /// email, the workspace is added, or "signed in as X, but this entry is X" makes no sense.
    private func name(of identity: CodexAccountIdentity, besides others: [CodexAccountIdentity] = []) -> String {
        guard let email = identity.email else { return identity.accountID }
        let known = store.logins.compactMap(\.identity)
            + (externalIdentityKeys ?? []).compactMap(CodexAccountIdentity.init(key:))
            + others
        let shared = known.contains { $0.email == email && $0.accountID != identity.accountID }
        return shared ? "\(email) (\(identity.workspaceLabel.lowercased()))" : email
    }

    private func start(loginID: UUID?, _ work: @escaping @MainActor () async throws -> String) {
        guard !isBusy else {
            AppLog.warn(LogTag.auth("codex"), "ignoring a Codex sign-in request while another is running")
            return
        }
        guard !store.loadFailed else {
            phase = .failed(CodexManagedLoginError.registryUnreadable.localizedDescription)
            return
        }
        let operation = UUID()
        currentOperation = operation
        phase = .signingIn(loginID: loginID, url: nil)
        operationTask = Task { [weak self] in
            guard let self else { return }
            let outcome: Phase
            do {
                let message = try await work()
                guard currentOperation == operation else { return }
                // The change is on disk; the cards follow before the outcome is shown.
                phase = .applying
                await onAccountsChanged()
                outcome = .succeeded(message)
            } catch is CancellationError {
                outcome = .failed(CodexManagedLoginError.cancelled.localizedDescription)
                AppLog.info(LogTag.auth("codex"), "managed login cancelled")
            } catch CodexLoginLaunchError.timedOut {
                outcome = .failed(CodexManagedLoginError.timedOut.localizedDescription)
                AppLog.warn(LogTag.auth("codex"), "managed login timed out")
            } catch let error as CodexLoginLaunchError {
                // `spawnFailed`: the CLI never ran. The description carries the system's reason, the
                // log keeps the raw code as well.
                outcome = .failed(error.localizedDescription)
                AppLog.error(LogTag.auth("codex"), "managed login could not start: \(error)")
            } catch let error as CodexManagedLoginError {
                outcome = .failed(error.localizedDescription)
                AppLog.warn(LogTag.auth("codex"), "managed login failed: \(error.logCode)")
            } catch {
                outcome = .failed(error.localizedDescription)
                AppLog.warn(LogTag.auth("codex"), "managed login failed: \(error.localizedDescription)")
            }
            guard currentOperation == operation else { return }
            phase = outcome
            operationTask = nil
        }
    }

    /// Rebuilds the cards for a change that is already saved (Remove), then shows `message`.
    private func apply(outcome message: String) {
        let operation = UUID()
        currentOperation = operation
        phase = .applying
        operationTask = Task { [weak self] in
            guard let self else { return }
            await onAccountsChanged()
            guard currentOperation == operation else { return }
            phase = .succeeded(message)
            operationTask = nil
        }
    }

    /// Reports the sign-in page into the current operation's phase; a stale operation's URL is dropped.
    private func urlReporter() -> @Sendable (String) -> Void {
        let operation = currentOperation
        return { [weak self] url in
            Task { @MainActor in
                guard let self, self.currentOperation == operation,
                      case .signingIn(let id, _) = self.phase else { return }
                self.phase = .signingIn(loginID: id, url: url)
            }
        }
    }

    private func makeHome(prefix: String = "") throws -> URL {
        let home = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try createPrivateDirectory(home)
        return home
    }

    private func createPrivateDirectory(_ directory: URL) throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// The record's home, only when it is a real directory OpenUsage created directly under the
    /// managed root — a registry entry pointing anywhere else (or through a symlink) is never
    /// written to or deleted. A missing folder passes (the callers recreate or skip it); a folder
    /// that cannot be inspected does not, so the error reaches the user instead of reading as absent.
    private func ownedHome(of login: CodexManagedLogin) throws -> URL {
        let home = URL(fileURLWithPath: login.home).standardizedFileURL
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard home.deletingLastPathComponent().resolvingSymlinksInPath().path == resolvedRoot,
              !home.lastPathComponent.isEmpty, home.lastPathComponent != ".."
        else { throw CodexManagedLoginError.unsafeHome }
        let type: FileAttributeType?
        do {
            type = try fileManager.attributesOfItem(atPath: home.path)[.type] as? FileAttributeType
        } catch let error where Self.isMissingFile(error) {
            type = nil
        }
        if let type, type != .typeDirectory { throw CodexManagedLoginError.unsafeHome }
        return home
    }

    /// "No such file", as FileManager (Cocoa) or a raw POSIX call reports it.
    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    /// `ownedHome`, recreated private (0700) when the folder went missing, so the credential writer
    /// never has to create it with default permissions.
    private func ensureOwnedHome(of login: CodexManagedLogin) throws -> URL {
        let home = try ownedHome(of: login)
        if !fileManager.fileExists(atPath: home.path) { try createPrivateDirectory(home) }
        return home
    }

    @discardableResult
    private func removeHomeBestEffort(_ home: URL) -> Bool {
        do {
            try fileManager.removeItem(at: home)
            return true
        } catch {
            AppLog.warn(LogTag.auth("codex"), "could not clean up a managed Codex home: \(error.localizedDescription)")
            return false
        }
    }

    /// Folders under the managed root that no record names: a sign-in the app quit out of, or a
    /// staging folder from a crash. They may hold a live credential, so they go at the next launch.
    /// A root that cannot be listed, or a folder that cannot be removed, is reported — the credential
    /// in it has no Remove row, so silence would leave it behind for good.
    private func sweepOrphanHomes() {
        let known = Set(store.logins.map { URL(fileURLWithPath: $0.home).lastPathComponent })
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch let error where Self.isMissingFile(error) {
            return // No account was ever added.
        } catch {
            AppLog.error(LogTag.auth("codex"), "could not list the managed Codex homes: \(error.localizedDescription)")
            phase = .failed("OpenUsage couldn't check its Codex account folders: \(error.localizedDescription)")
            return
        }
        var failed = 0
        for entry in entries where !known.contains(entry.lastPathComponent) {
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                AppLog.error(LogTag.auth("codex"), "could not inspect a managed Codex home: \(error.localizedDescription)")
                failed += 1
                continue
            }
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if removeHomeBestEffort(entry) {
                AppLog.info(LogTag.auth("codex"), "removed an orphaned managed Codex home")
            } else {
                failed += 1
            }
        }
        if failed > 0 {
            phase = .failed("OpenUsage couldn't remove \(failed) leftover Codex sign-in folder\(failed == 1 ? "" : "s"). Check the log for details.")
        }
    }
}
