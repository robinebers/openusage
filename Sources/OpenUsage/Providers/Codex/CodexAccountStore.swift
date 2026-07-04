import Foundation
import Observation

struct CodexAccountRecord: Codable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case managed
        case cliFile
        case cliKeychain
    }

    var id: String
    var identity: String
    var providerID: String
    var displayName: String
    var source: Source
    var keychainService: String?
    var authPath: String?
    var hidden: Bool
}

struct CodexAccountContext: Sendable {
    var record: CodexAccountRecord
    var authStore: CodexAuthStore
    var logUsageScanner: CodexLogUsageScanner
}

@MainActor
@Observable
final class CodexAccountStore {
    private static let metadataKey = "openusage.codex.accounts.v1"
    private static let hiddenCLIKey = "openusage.codex.hiddenCLIIdentities.v1"
    private static let managedKeychainPrefix = "OpenUsage Codex Account"

    private let defaults: UserDefaults
    private let keychain: KeychainAccessing
    private let environment: EnvironmentReading
    private let files: TextFileAccessing
    private let homeDirectory: @Sendable () -> URL

    private(set) var managedAccounts: [CodexAccountRecord]
    private(set) var lastError: String?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.environment = environment
        self.files = files
        self.homeDirectory = homeDirectory
        self.managedAccounts = Self.decodeManagedAccounts(from: defaults)
    }

    func accountContexts() -> [CodexAccountContext] {
        let visibleManaged = managedAccounts.filter { !$0.hidden }
        let cliRecords = discoverCLIAccounts(hiddenIdentities: hiddenCLIIdentities())
        var records = Self.mergeAndAssignProviderIDs(managed: visibleManaged, cli: cliRecords)
        if records.isEmpty {
            records = [CodexAccountRecord(
                id: "default",
                identity: "default",
                providerID: "codex",
                displayName: "Codex",
                source: .cliFile,
                keychainService: nil,
                authPath: nil,
                hidden: false
            )]
        }
        return records.map { record in
            CodexAccountContext(
                record: record,
                authStore: authStore(for: record),
                logUsageScanner: logScanner(for: record)
            )
        }
    }

    func visibleRecords() -> [CodexAccountRecord] {
        accountContexts().map(\.record)
    }

    func settingsRecords() -> [CodexAccountRecord] {
        Self.mergeAndAssignProviderIDs(
            managed: managedAccounts.filter { !$0.hidden },
            cli: discoverCLIAccounts(hiddenIdentities: hiddenCLIIdentities())
        )
    }

    func saveManagedAuth(_ auth: CodexAuth) throws -> CodexAccountRecord {
        let identity = Self.identity(for: auth) ?? "local-\(UUID().uuidString)"
        let service = Self.managedService(identity: identity)
        let encoder = JSONEncoder()
        let data = try encoder.encode(auth)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAuthError.invalidAuthPayload
        }
        try keychain.writeGenericPassword(service: service, value: text)

        var next = managedAccounts
        if let index = next.firstIndex(where: { $0.identity == identity }) {
            next[index].hidden = false
            next[index].keychainService = service
        } else {
            let displayName = next.isEmpty ? "Codex" : "Codex \(next.count + 1)"
            next.append(CodexAccountRecord(
                id: identity,
                identity: identity,
                providerID: "",
                displayName: displayName,
                source: .managed,
                keychainService: service,
                authPath: nil,
                hidden: false
            ))
        }
        managedAccounts = next
        persistManagedAccounts()
        lastError = nil
        return managedAccounts.first { $0.identity == identity }!
    }

    func rename(_ record: CodexAccountRecord, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = managedAccounts.firstIndex(where: { $0.identity == record.identity })
        else { return }
        managedAccounts[index].displayName = trimmed
        persistManagedAccounts()
    }

    func removeManaged(_ record: CodexAccountRecord) {
        guard record.source == .managed else { return }
        do {
            if let service = record.keychainService {
                try keychain.deleteGenericPassword(service: service)
            }
            managedAccounts.removeAll { $0.identity == record.identity }
            persistManagedAccounts()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            AppLog.error(LogTag.auth("codex"), "failed to remove managed Codex account: \(error.localizedDescription)")
        }
    }

    func hideCLI(_ record: CodexAccountRecord) {
        guard record.source != .managed else { return }
        var hidden = hiddenCLIIdentities()
        hidden.insert(record.identity)
        defaults.set(Array(hidden).sorted(), forKey: Self.hiddenCLIKey)
    }

    private func authStore(for record: CodexAccountRecord) -> CodexAuthStore {
        switch record.source {
        case .managed:
            return CodexAuthStore(
                environment: environment,
                files: files,
                keychain: keychain,
                authPathsOverride: [],
                keychainService: record.keychainService ?? Self.managedService(identity: record.identity)
            )
        case .cliFile:
            guard let authPath = record.authPath else {
                return CodexAuthStore(environment: environment, files: files, keychain: keychain)
            }
            return CodexAuthStore(
                environment: environment,
                files: files,
                keychain: keychain,
                authPathsOverride: [authPath],
                keychainService: "__unused__"
            )
        case .cliKeychain:
            return CodexAuthStore(
                environment: environment,
                files: files,
                keychain: keychain,
                authPathsOverride: [],
                keychainService: CodexAuthStore.defaultKeychainService
            )
        }
    }

    private func logScanner(for record: CodexAccountRecord) -> CodexLogUsageScanner {
        if record.source == .cliFile, let path = record.authPath {
            let home = URL(fileURLWithPath: path).deletingLastPathComponent()
            return CodexLogUsageScanner(homesOverride: [home])
        }
        return CodexLogUsageScanner(environment: environment, homeDirectory: homeDirectory)
    }

    private func discoverCLIAccounts(hiddenIdentities: Set<String>) -> [CodexAccountRecord] {
        let store = CodexAuthStore(environment: environment, files: files, keychain: keychain)
        let (fileCandidates, _) = store.loadAuthCandidates()
        var records: [CodexAccountRecord] = []
        for candidate in fileCandidates where candidate.hasUsableAccessToken {
            guard let identity = Self.identity(for: candidate.auth),
                  !hiddenIdentities.contains(identity)
            else { continue }
            let path: String?
            if case .file(let value) = candidate.source { path = value } else { path = nil }
            records.append(CodexAccountRecord(
                id: identity,
                identity: identity,
                providerID: "",
                displayName: "Codex",
                source: .cliFile,
                keychainService: nil,
                authPath: path,
                hidden: false
            ))
        }
        if let keychainState = store.loadKeychainAuth(),
           keychainState.hasUsableAccessToken,
           let identity = Self.identity(for: keychainState.auth),
           !hiddenIdentities.contains(identity) {
            records.append(CodexAccountRecord(
                id: identity,
                identity: identity,
                providerID: "",
                displayName: "Codex",
                source: .cliKeychain,
                keychainService: CodexAuthStore.defaultKeychainService,
                authPath: nil,
                hidden: false
            ))
        }
        return records
    }

    private static func mergeAndAssignProviderIDs(
        managed: [CodexAccountRecord],
        cli: [CodexAccountRecord]
    ) -> [CodexAccountRecord] {
        var merged: [CodexAccountRecord] = []
        var seen = Set<String>()
        let managedByIdentity = Dictionary(uniqueKeysWithValues: managed.map { ($0.identity, $0) })
        for record in cli {
            let preferred = managedByIdentity[record.identity] ?? record
            guard !seen.contains(preferred.identity) else { continue }
            seen.insert(preferred.identity)
            merged.append(preferred)
        }
        for record in managed where !seen.contains(record.identity) {
            seen.insert(record.identity)
            merged.append(record)
        }
        return merged.enumerated().map { index, record in
            var copy = record
            copy.providerID = index == 0 ? "codex" : "codex.\(shortHash(record.identity))"
            if copy.displayName == "Codex", index > 0 {
                copy.displayName = "Codex \(index + 1)"
            }
            return copy
        }
    }

    static func identity(for auth: CodexAuth) -> String? {
        if let accountID = auth.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            return "account:\(accountID)"
        }
        if let idToken = auth.tokens?.idToken,
           let sub = ProviderParse.jwtPayload(idToken)?["sub"] as? String,
           !sub.isEmpty {
            return "sub:\(sub)"
        }
        if let accessToken = auth.tokens?.accessToken,
           let sub = ProviderParse.jwtPayload(accessToken)?["sub"] as? String,
           !sub.isEmpty {
            return "access-sub:\(sub)"
        }
        return nil
    }

    private func hiddenCLIIdentities() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.hiddenCLIKey) ?? [])
    }

    private func persistManagedAccounts() {
        do {
            defaults.set(try JSONEncoder().encode(managedAccounts), forKey: Self.metadataKey)
        } catch {
            AppLog.warn(.config, "failed to persist Codex accounts: \(error.localizedDescription)")
        }
    }

    private static func decodeManagedAccounts(from defaults: UserDefaults) -> [CodexAccountRecord] {
        guard let data = defaults.data(forKey: metadataKey) else { return [] }
        do {
            return try JSONDecoder().decode([CodexAccountRecord].self, from: data)
        } catch {
            AppLog.warn(.config, "saved Codex accounts failed to decode: \(error.localizedDescription)")
            return []
        }
    }

    private static func managedService(identity: String) -> String {
        "\(managedKeychainPrefix) \(shortHash(identity))"
    }

    private static func shortHash(_ value: String) -> String {
        String(value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }, radix: 16)
    }
}

private func shortHash(_ value: String) -> String {
    String(value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
        (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }, radix: 16)
}
