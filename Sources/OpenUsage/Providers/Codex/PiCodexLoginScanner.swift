import Foundation

/// An `openai-codex` / `openai-codex-N` OAuth login in pi's `auth.json`.
struct PiCodexLogin: Equatable, Sendable {
    let providerID: String
    let identity: CodexAccountIdentity
    let label: String?
    let authPath: String
}

struct PiCodexLoginScan: Equatable, Sendable {
    let logins: [PiCodexLogin]

    static let empty = PiCodexLoginScan(logins: [])
}

/// Reads pi's Codex logins. Never writes: pi rotates its own tokens under a lockfile.
struct PiCodexLoginScanner: Sendable {
    static let providerPrefix = "openai-codex"

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.environment = environment
        self.files = files
        self.homeDirectory = homeDirectory
    }

    /// `openai-codex`, or `openai-codex-N` for pi's multi-pass pool (`openai-codex-work` is not pi's).
    static func isCodexProvider(_ providerID: String) -> Bool {
        guard providerID.hasPrefix(providerPrefix) else { return false }
        let suffix = providerID.dropFirst(providerPrefix.count)
        if suffix.isEmpty { return true }
        guard suffix.first == "-" else { return false }
        let digits = suffix.dropFirst()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    static func providerIndex(_ providerID: String) -> Int {
        let suffix = providerID.dropFirst(providerPrefix.count)
        guard suffix.hasPrefix("-"), let index = Int(suffix.dropFirst()) else { return 1 }
        return index
    }

    func agentDirectory() -> String {
        if let configDir = environment.value(for: "PI_CODING_AGENT_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return CodexHomeScanner.expandTilde(configDir, homeDirectory: homeDirectory()).trimmingTrailingSlashes
        }
        return homeDirectory().appendingPathComponent(".pi/agent").path
    }

    func scan() -> PiCodexLoginScan {
        let agentDir = agentDirectory()
        let authPath = agentDir + "/auth.json"
        let object: [String: Any]
        do {
            guard let text = try files.readTextIfPresent(authPath) else { return .empty }
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                AppLog.error(.config, "accounts: pi auth.json is not a JSON object; pi Codex logins skipped")
                return .empty
            }
            object = parsed
        } catch {
            AppLog.error(.config, "accounts: pi auth.json could not be read; pi Codex logins skipped")
            return .empty
        }
        let labels = subscriptionLabels(agentDir: agentDir)
        let providerIDs = object.keys
            .filter(Self.isCodexProvider)
            .sorted { Self.providerIndex($0) < Self.providerIndex($1) }
        var logins: [PiCodexLogin] = []
        for providerID in providerIDs {
            guard let auth = Self.auth(in: object, providerID: providerID),
                  let identity = CodexAccountIdentity(auth: auth),
                  CodexAccountIdentity.isComplete(key: identity.key)
            else { continue }
            logins.append(PiCodexLogin(
                providerID: providerID, identity: identity, label: labels[providerID], authPath: authPath
            ))
        }
        return PiCodexLoginScan(logins: logins)
    }

    /// The live credential for one pi provider entry — re-read on every use, never cached.
    static func loadAuth(files: TextFileAccessing, path: String, providerID: String) -> CodexAuth? {
        guard let text = try? files.readTextIfPresent(path),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return auth(in: object, providerID: providerID)
    }

    private static func auth(in object: [String: Any], providerID: String) -> CodexAuth? {
        guard let entry = object[providerID] as? [String: Any],
              entry["type"] as? String == "oauth",
              let accessToken = (entry["access"] as? String)?.nilIfEmpty
        else { return nil }
        return CodexAuth(tokens: CodexTokens(
            accessToken: accessToken,
            refreshToken: nil,
            idToken: nil,
            accountID: (entry["accountId"] as? String)?.nilIfEmpty
        ), lastRefresh: nil, apiKey: nil)
    }

    private func subscriptionLabels(agentDir: String) -> [String: String] {
        guard let text = try? files.readTextIfPresent(agentDir + "/multi-pass.json"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let subscriptions = object["subscriptions"] as? [[String: Any]]
        else { return [:] }
        var labels: [String: String] = [:]
        for subscription in subscriptions {
            guard subscription["provider"] as? String == Self.providerPrefix,
                  let index = ProviderParse.number(subscription["index"]).map({ Int($0) }),
                  let label = (subscription["label"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else { continue }
            let providerID = index <= 1 ? Self.providerPrefix : "\(Self.providerPrefix)-\(index)"
            labels[providerID] = label
        }
        return labels
    }
}
