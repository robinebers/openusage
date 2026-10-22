import Foundation
import Observation

/// One Codex login OpenUsage signed in itself, into a private home it owns. The record id is
/// bookkeeping for this store only — the dashboard card keeps the account registry's id, so a
/// managed login attaches to whatever card already shows that account.
struct CodexManagedLogin: Equatable, Identifiable, Sendable {
    var id: UUID
    /// Absolute path of the private Codex home holding this login's `auth.json`. Resolved by the
    /// store from the folder name it persists, so a moved home directory or restored settings file
    /// never strands a record on a path that no longer exists.
    var home: String
    /// `workspace|email`, verified from the login's own tokens right after the CLI signed in.
    var identityKey: String
    var createdAt: Date
    var lastSignedInAt: Date

    var identity: CodexAccountIdentity? { CodexAccountIdentity(key: identityKey) }
}

/// The managed-login registry (`openusage.codexManagedLogins.v1`). Read by the launch account pass
/// (app and one-shot CLI alike) so managed homes join Codex discovery; written only by the
/// account-management actions in Customize.
@MainActor
@Observable
final class CodexManagedAccountStore {
    static let storageKey = "openusage.codexManagedLogins.v1"

    /// The persisted shape: only the home's folder name, never its absolute path.
    private struct StoredLogin: Codable {
        var id: UUID
        var folder: String
        var identityKey: String
        var createdAt: Date
        var lastSignedInAt: Date
    }

    let root: URL
    private let defaults: UserDefaults
    private(set) var logins: [CodexManagedLogin]
    /// The persisted list exists but could not be read. The service then neither sweeps the root
    /// nor writes the list, so the homes those records point at are never mistaken for orphans.
    let loadFailed: Bool

    init(defaults: UserDefaults = .standard, root: URL = CodexManagedAccountStore.managedRoot()) {
        self.defaults = defaults
        self.root = root
        var stored: [StoredLogin] = []
        var loadFailed = false
        // `object(forKey:)` rather than `data(forKey:)`: a value of the wrong type (a restored or
        // hand-edited plist) must read as a broken list, never as "no list" — the latter would let
        // the orphan sweep delete every home the broken list names.
        if let value = defaults.object(forKey: Self.storageKey) {
            if let data = value as? Data {
                do {
                    stored = try Self.decoder.decode([StoredLogin].self, from: data)
                    // A folder is one name directly under the root. A restored or hand-edited list
                    // whose folder climbs out (`../../.codex`) would make that home a managed one:
                    // skipped by the duplicate check, rotated into by every refresh. Such a list is
                    // as broken as an undecodable one, and nothing is mapped from it.
                    if stored.contains(where: { !Self.isFolderName($0.folder) }) {
                        stored = []
                        loadFailed = true
                        AppLog.error(.config, "a managed Codex login names a folder outside the managed root; account management is paused until the list is repaired")
                    }
                } catch {
                    loadFailed = true
                    AppLog.error(.config, "managed Codex logins are undecodable; account management is paused until the list is repaired: \(error.localizedDescription)")
                }
            } else {
                loadFailed = true
                AppLog.error(.config, "managed Codex logins are stored as \(type(of: value)) instead of data; account management is paused until the list is repaired")
            }
        }
        self.loadFailed = loadFailed
        self.logins = stored.map { login in
            CodexManagedLogin(
                id: login.id, home: root.appendingPathComponent(login.folder, isDirectory: true).path,
                identityKey: login.identityKey, createdAt: login.createdAt, lastSignedInAt: login.lastSignedInAt
            )
        }
    }

    /// The folder every managed home lives under. Private to the current user and split by bundle
    /// id, so a dev build (its own bundle id and settings) never sweeps or reuses the release
    /// build's homes.
    static func managedRoot(
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL {
        applicationSupport
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("codex-accounts", isDirectory: true)
            .appendingPathComponent(bundleIdentifier ?? "unbundled", isDirectory: true)
    }

    /// One path component, never `.` or `..`: the only shape `persist` ever writes.
    private static func isFolderName(_ folder: String) -> Bool {
        !folder.isEmpty && folder != "." && folder != ".." && !folder.contains("/")
    }

    func login(identityKey: String) -> CodexManagedLogin? {
        logins.first { $0.identityKey == identityKey }
    }

    func upsert(_ login: CodexManagedLogin) {
        if let index = logins.firstIndex(where: { $0.id == login.id }) {
            logins[index] = login
        } else {
            logins.append(login)
        }
        persist()
    }

    func remove(id: UUID) {
        logins.removeAll { $0.id == id }
        persist()
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func persist() {
        guard !loadFailed else {
            AppLog.error(.config, "refusing to overwrite the undecodable managed Codex login list")
            return
        }
        let stored = logins.map { login in
            StoredLogin(
                id: login.id, folder: URL(fileURLWithPath: login.home).lastPathComponent,
                identityKey: login.identityKey, createdAt: login.createdAt, lastSignedInAt: login.lastSignedInAt
            )
        }
        guard let data = try? Self.encoder.encode(stored) else {
            AppLog.error(.config, "failed to encode managed Codex logins; keeping previous persisted state")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
