import Foundation

/// A ChatGPT workspace and the user signed into it. Email is part of xswap's identity contract.
struct CodexAccountIdentity: Equatable, Hashable, Sendable {
    /// Empty only for a default login whose token identifies the user but omits the workspace.
    let accountID: String
    let email: String?

    var key: String { accountID + "|" + (email ?? "") }

    static func isComplete(key: String) -> Bool {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
    }

    init?(accountID: String?, email: String?) {
        let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.lowercased()
        guard accountID != nil || email != nil,
              accountID.map(Self.validComponent) ?? true,
              email.map(Self.validComponent) ?? true else { return nil }
        self.accountID = accountID?.lowercased() ?? ""
        self.email = email
    }

    init?(auth: CodexAuth) {
        let payload = auth.tokens?.idToken.flatMap(ProviderParse.jwtPayload)
        let claimID = DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: payload)
        let storedID = auth.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let storedID, let claimID,
           storedID.caseInsensitiveCompare(claimID) != .orderedSame { return nil }
        self.init(accountID: storedID ?? claimID, email: payload?["email"] as? String)
    }

    private static func validComponent(_ value: String) -> Bool {
        value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/\\|"))) == nil
    }
}

/// Reads metadata without invoking xswap, running aliases, or touching the registry's lock files.
struct CodexSwapAccount: Equatable, Sendable {
    let number: Int
    let alias: String?
    let identity: CodexAccountIdentity
    let home: String
    let mainHome: String
    let plan: String?
    let shareHistory: Bool

    var displayName: String {
        let label = alias ?? "Workspace \(identity.accountID.prefix(8))"
        return "Codex: \(label) (\(identity.email ?? identity.accountID))"
    }

    static func discover(
        environment: EnvironmentReading, files: TextFileAccessing, home: URL
    ) -> [Self] {
        let root: String
        if let override = environment.value(for: "XSWAP_HOME")?.nilIfEmpty {
            root = override.hasPrefix("~/") ? home.path + String(override.dropFirst()) : override
        } else if let xdg = environment.value(for: "XDG_DATA_HOME"), xdg.hasPrefix("/") {
            root = xdg.trimmingTrailingSlashes + "/codex-swap"
        } else {
            root = home.appendingPathComponent(".local/share/codex-swap").path
        }
        do {
            guard let text = try files.readTextIfPresent(root + "/accounts.json") else { return [] }
            let registry = try JSONDecoder().decode(Registry.self, from: Data(text.utf8))
            guard registry.schemaVersion == 1, validPath(registry.mainHome) else {
                AppLog.error(.config, "Codex Swap registry has an unsupported version or invalid main home")
                return []
            }
            var numbers = Set<Int>()
            return registry.accounts.sorted { $0.number < $1.number }.compactMap { account in
                guard account.number > 0, numbers.insert(account.number).inserted,
                      validPath(account.home),
                      let identity = CodexAccountIdentity(accountID: account.identity?.accountId,
                                                         email: account.identity?.email),
                      !identity.accountID.isEmpty
                else {
                    AppLog.warn(.config, "Codex Swap account has no usable identity or home; skipping it")
                    return nil
                }
                // Disabled slots still have valid logins, and xswap permits explicit launches of them.
                return Self(number: account.number, alias: account.alias?.nilIfEmpty,
                            identity: identity, home: account.home, mainHome: registry.mainHome,
                            plan: account.identity?.plan, shareHistory: account.shareHistory ?? false)
            }
        } catch {
            // Decoder errors can contain credential material from a malformed registry.
            AppLog.error(.config, "Codex Swap account registry could not be read or decoded")
            return []
        }
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0")
    }

    private struct Registry: Decodable {
        let schemaVersion: Int
        let mainHome: String
        let accounts: [Account]
    }

    private struct Account: Decodable {
        let number: Int
        let alias: String?
        let home: String
        let identity: Identity?
        let shareHistory: Bool?
    }

    private struct Identity: Decodable {
        let accountId: String
        let email: String?
        let plan: String?
    }
}
