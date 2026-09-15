import Foundation

struct CodexHomeLogin: Equatable, Sendable {
    let home: String
    let accountID: String
    let email: String?
    let planType: String?

    var authPath: String { home + "/auth.json" }
}

struct PiCodexLogin: Equatable, Sendable {
    let providerID: String
    let accountID: String
    let email: String?
    let planType: String?
    let label: String?
    let accessToken: String
    let expiresAt: Date?
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
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            return url.lastPathComponent
        }
    }


    func candidateHomes() -> [String] {
        let home = homeDirectory().path
        var homes: [String] = []
        if let raw = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            homes += raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        homes += ["~/.config/codex", "~/.codex"]
        homes += listDirectories(home)
            .filter { $0.hasPrefix(".codex-") }
            .sorted()
            .map { "~/\($0)" }
        homes += listDirectories(home + "/.config")
            .filter { $0.hasPrefix("codex-") }
            .sorted()
            .map { "~/.config/\($0)" }

        var seen: Set<String> = []
        return homes.compactMap { raw in
            let expanded = expandTilde(raw).trimmingTrailingSlashes
            let key = URL(fileURLWithPath: expanded).standardizedFileURL.path
            return seen.insert(key).inserted ? expanded : nil
        }
    }

    func homeLogins() -> [CodexHomeLogin] {
        candidateHomes().compactMap { home in
            let text: String?
            do {
                text = try files.readTextIfPresent(home + "/auth.json")
            } catch {
                AppLog.warn(.config, "accounts: Codex home \(home) has an unreadable auth.json; skipping it")
                return nil
            }
            guard let text,
                  let auth = CodexAuthStore.parseAuth(text),
                  auth.tokens?.accessToken?.nilIfEmpty != nil
            else { return nil }
            let payload = auth.tokens?.idToken.flatMap { ProviderParse.jwtPayload($0) }
                ?? auth.tokens?.accessToken.flatMap { ProviderParse.jwtPayload($0) }
            let accountID = auth.tokens?.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: payload)
            guard let accountID else {
                AppLog.info(.config, "accounts: Codex home \(home) names no account; not a card")
                return nil
            }
            return CodexHomeLogin(
                home: home,
                accountID: accountID.lowercased(),
                email: Self.email(inTokenPayload: payload),
                planType: Self.planType(inTokenPayload: payload)
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
            return expandTilde(configDir).trimmingTrailingSlashes
        }
        return homeDirectory().appendingPathComponent(".pi/agent").path
    }

    func piLogins() -> [PiCodexLogin] {
        let agentDir = piAgentDirectory()
        let object: [String: Any]
        do {
            guard let text = try files.readTextIfPresent(agentDir + "/auth.json") else { return [] }
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
            .compactMap { providerID -> PiCodexLogin? in
                guard let entry = object[providerID] as? [String: Any],
                      entry["type"] as? String == "oauth",
                      let accessToken = (entry["access"] as? String)?.nilIfEmpty
                else { return nil }
                let payload = ProviderParse.jwtPayload(accessToken)
                let accountID = (entry["accountId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: payload)
                guard let accountID else {
                    AppLog.info(.config, "accounts: pi login \(providerID) names no account; not a card")
                    return nil
                }
                let expiresAt = ProviderParse.number(entry["expires"]).map { Date(timeIntervalSince1970: $0 / 1000) }
                return PiCodexLogin(
                    providerID: providerID,
                    accountID: accountID.lowercased(),
                    email: Self.email(inTokenPayload: payload),
                    planType: Self.planType(inTokenPayload: payload),
                    label: labels[providerID],
                    accessToken: accessToken,
                    expiresAt: expiresAt
                )
            }
    }

    static func piProviderIndex(_ providerID: String) -> Int {
        let suffix = providerID.dropFirst(piCodexProviderPrefix.count)
        guard suffix.hasPrefix("-"), let index = Int(suffix.dropFirst()) else { return 1 }
        return index
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


    static func email(inTokenPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        return ((profile?["email"] ?? payload["email"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func planType(inTokenPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let authClaim = payload["https://api.openai.com/auth"] as? [String: Any]
        return (authClaim?["chatgpt_plan_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }
}
