import Foundation

struct CodexHomeLogin: Equatable, Sendable {
    let home: String
    let identity: CodexAccountIdentity
    let planType: String?

    var authPath: String { home + "/auth.json" }
}

struct PiCodexLogin: Equatable, Sendable {
    let providerID: String
    let identity: CodexAccountIdentity
    let planType: String?
    let label: String?
    let authPath: String
}

struct CodexAccountDiscovery: Sendable {
    var environment: EnvironmentReading
    var files: TextFileAccessing
    var homeDirectory: @Sendable () -> URL
    var listDirectories: @Sendable (String) -> [String]

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listDirectories: @escaping @Sendable (String) -> [String] = Self.listSubdirectories
    ) {
        self.environment = environment
        self.files = files
        self.homeDirectory = homeDirectory
        self.listDirectories = listDirectories
    }

    static func listSubdirectories(_ path: String) -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { return nil }
            return url.lastPathComponent
        }
    }

    static func configuredHomeValues(environment: EnvironmentReading) -> [String] {
        let homes = environment.value(for: "CODEX_HOME")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return homes.isEmpty ? ["~/.config/codex", "~/.codex"] : homes
    }

    static func configuredHomes(environment: EnvironmentReading, homeDirectory: URL) -> [String] {
        uniqueHomes(configuredHomeValues(environment: environment), homeDirectory: homeDirectory)
    }

    func candidateHomes() -> [String] {
        let home = homeDirectory()
        let siblingHomes = listDirectories(home.path)
            .filter { $0.hasPrefix(".codex-") }
            .sorted()
            .map { "~/\($0)" }
            + listDirectories(home.appendingPathComponent(".config").path)
            .filter { $0.hasPrefix("codex-") }
            .sorted()
            .map { "~/.config/\($0)" }
        return Self.uniqueHomes(
            Self.configuredHomes(environment: environment, homeDirectory: home) + ["~/.config/codex", "~/.codex"] + siblingHomes,
            homeDirectory: home
        )
    }

    func homeLogins(additionalHomes: [String] = []) -> [CodexHomeLogin] {
        let homes = Self.uniqueHomes(
            candidateHomes() + additionalHomes,
            homeDirectory: homeDirectory()
        )
        return homes.compactMap { home in
            let text: String?
            do {
                text = try files.readTextIfPresent(home + "/auth.json")
            } catch {
                AppLog.warn(.config, "accounts: Codex home \(home) has an unreadable auth.json; skipping it")
                return nil
            }
            guard let text,
                  let auth = CodexAuthStore.parseAuth(text),
                  auth.tokens?.accessToken?.nilIfEmpty != nil,
                  let identity = CodexAccountIdentity(auth: auth)
            else { return nil }
            return CodexHomeLogin(
                home: home,
                identity: identity,
                planType: Self.planType(inTokenPayload: Self.identityPayload(auth))
            )
        }
    }

    static let piCodexProviderPrefix = "openai-codex"

    static func isPiCodexProvider(_ providerID: String) -> Bool {
        guard providerID.hasPrefix(piCodexProviderPrefix) else { return false }
        let suffix = providerID.dropFirst(piCodexProviderPrefix.count)
        if suffix.isEmpty { return true }
        guard suffix.first == "-" else { return false }
        let digits = suffix.dropFirst()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    func piAgentDirectory() -> String {
        if let configDir = environment.value(for: "PI_CODING_AGENT_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return Self.expandTilde(configDir, homeDirectory: homeDirectory()).trimmingTrailingSlashes
        }
        return homeDirectory().appendingPathComponent(".pi/agent").path
    }

    func piLogins() -> [PiCodexLogin] {
        let agentDir = piAgentDirectory()
        let authPath = agentDir + "/auth.json"
        let object: [String: Any]
        do {
            guard let text = try files.readTextIfPresent(authPath) else { return [] }
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                AppLog.error(.config, "accounts: pi auth.json is not a JSON object; pi Codex logins skipped")
                return []
            }
            object = parsed
        } catch {
            AppLog.error(.config, "accounts: pi auth.json could not be read; pi Codex logins skipped")
            return []
        }
        let labels = piSubscriptionLabels(agentDir: agentDir)
        return object.keys
            .filter(Self.isPiCodexProvider)
            .sorted { Self.piProviderIndex($0) < Self.piProviderIndex($1) }
            .compactMap { providerID in
                guard let auth = Self.piAuth(in: object, providerID: providerID),
                      let identity = CodexAccountIdentity(auth: auth),
                      CodexAccountIdentity.isComplete(key: identity.key)
                else { return nil }
                return PiCodexLogin(
                    providerID: providerID,
                    identity: identity,
                    planType: Self.planType(inTokenPayload: Self.identityPayload(auth)),
                    label: labels[providerID],
                    authPath: authPath
                )
            }
    }

    static func loadPiAuth(files: TextFileAccessing, path: String, providerID: String) -> CodexAuth? {
        guard let text = try? files.readTextIfPresent(path),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return piAuth(in: object, providerID: providerID)
    }

    static func piProviderIndex(_ providerID: String) -> Int {
        let suffix = providerID.dropFirst(piCodexProviderPrefix.count)
        guard suffix.hasPrefix("-"), let index = Int(suffix.dropFirst()) else { return 1 }
        return index
    }

    static func identityPayload(_ auth: CodexAuth) -> [String: Any]? {
        if let payload = auth.tokens?.idToken.flatMap(ProviderParse.jwtPayload),
           DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: payload) != nil {
            return payload
        }
        return auth.tokens?.accessToken.flatMap(ProviderParse.jwtPayload)
            ?? auth.tokens?.idToken.flatMap(ProviderParse.jwtPayload)
    }

    static func email(inTokenPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        return ((profile?["email"] ?? payload["email"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.lowercased()
    }

    static func planType(inTokenPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let authClaim = payload["https://api.openai.com/auth"] as? [String: Any]
        return (authClaim?["chatgpt_plan_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func piAuth(in object: [String: Any], providerID: String) -> CodexAuth? {
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

    private func piSubscriptionLabels(agentDir: String) -> [String: String] {
        guard let text = try? files.readTextIfPresent(agentDir + "/multi-pass.json"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let subscriptions = object["subscriptions"] as? [[String: Any]]
        else { return [:] }
        var labels: [String: String] = [:]
        for subscription in subscriptions {
            guard subscription["provider"] as? String == Self.piCodexProviderPrefix,
                  let index = ProviderParse.number(subscription["index"]).map({ Int($0) }),
                  let label = (subscription["label"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else { continue }
            let providerID = index <= 1 ? Self.piCodexProviderPrefix : "\(Self.piCodexProviderPrefix)-\(index)"
            labels[providerID] = label
        }
        return labels
    }

    private static func uniqueHomes(_ homes: [String], homeDirectory: URL) -> [String] {
        var seen = Set<String>()
        return homes.compactMap { raw in
            let expanded = expandTilde(raw, homeDirectory: homeDirectory).trimmingTrailingSlashes
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            return seen.insert(standardized).inserted ? standardized : nil
        }
    }

    private static func expandTilde(_ path: String, homeDirectory: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory.path + String(path.dropFirst(1))
    }
}
