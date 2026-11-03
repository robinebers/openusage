import Foundation

/// A CLIProxyAPI server the user connected with its management key. The hub owns its list of logins;
/// each supported login is mirrored as an ordinary Claude, ChatGPT, Antigravity, Devin, or Grok account
/// that carries a `HubLink`.
struct CLIProxyHub: Codable, Identifiable, Hashable, Sendable {
    /// The bundled mark (`ProviderIcons/cliproxyapi.svg`) on the hub's row and on its accounts' badge.
    static let markID = "cliproxyapi"
    /// The hub's off switch: while false, Add Account offers no hub, and a stored hub or an account's hub
    /// link reads no key and sends nothing.
    static let isEnabled = true
    static let offMessage = "CLIProxyAPI hubs are turned off in this version of OpenUsage."

    let id: UUID
    let url: URL
    let addedAt: Date

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
    }

    var host: String { Self.host(of: url) }

    static func host(of url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// The hub's base URL from what the user typed: the scheme defaults to https, and the query, the
    /// fragment, and a pasted panel or API path (`/management.html`, `/v0/management`, `/v1`) are
    /// dropped. A path the hub sits under behind a reverse proxy is kept.
    static func baseURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.path
        for suffix in ["/", "/management.html", "/v0/management", "/v8/management", "/v1"] {
            while path.lowercased().hasSuffix(suffix) { path.removeLast(suffix.count) }
        }
        components.path = path
        return components.url
    }

    /// Whether the management key may go to `url` at all: over https anywhere, and over http only to
    /// this Mac, a host on the local network (a private or link-local address, or a `.local` name), or a
    /// Tailscale peer (a `.ts.net` name or an address in 100.64.0.0/10 or fd7a:115c:a1e0::/48), whose
    /// traffic WireGuard encrypts.
    static func allowsKey(at url: URL) -> Bool {
        guard url.scheme == "http" else { return url.scheme == "https" }
        guard let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        if host.contains(":") { return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return false }
        return switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254), (172, 16...31), (100, 64...127): true
        default: false
        }
    }
}

/// Where a mirrored account's login lives on its hub. `loginID` is the hub's stable id for the login
/// (its file name); `authIndex` is what `api-call` takes, and it changes when the hub renames the file.
/// `chatGPTAccountID` is the ChatGPT workspace a Codex login is signed in to, which can change under the
/// same file.
struct HubLink: Codable, Hashable, Sendable {
    let hubID: UUID
    let hubURL: URL
    let loginID: String
    var authIndex: String
    var chatGPTAccountID: String?

    var host: String { CLIProxyHub.host(of: hubURL) }

    /// The account's stored sign-in: the hub's placeholder, which the hub swaps for its own token.
    var credential: AccountCredential {
        .oauth(OAuthTokens(
            accessToken: CLIProxyHubClient.tokenPlaceholder, extras: chatGPTAccountID.map { ["chatgpt_account_id": $0] } ?? [:]
        ))
    }

    /// Nil for a login the hub listed without an auth index, which can't be called.
    init?(hub: CLIProxyHub, login: HubLogin) {
        guard let authIndex = login.authIndex else { return nil }
        hubID = hub.id
        hubURL = hub.url
        loginID = login.id
        self.authIndex = authIndex
        chatGPTAccountID = login.chatGPTAccountID
    }
}

/// What it takes to make a hub's mirrored accounts match its login list, in the listing's order. A login
/// disabled on the hub counts as gone. A login missing from the list is removed only when the previous
/// list lacked it too, so a hub that answers mid-restart, or with a list cut short, never erases accounts.
/// A login listed without an auth index keeps its account as it is.
struct HubReconciliation {
    var added: [(kind: ProviderKind, label: String, link: HubLink)] = []
    var removed: [UUID] = []
    var relinked: [UUID: HubLink] = [:]
    /// The accounts whose logins this list lacks for the first time; they stay until the next list agrees.
    var missing: Set<UUID> = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && relinked.isEmpty }

    init(hub: CLIProxyHub, logins: [HubLogin], accounts: [Account], missingBefore: Set<UUID>) {
        let listed = Dictionary(logins.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var mirroredIDs = Set<String>()
        for account in accounts {
            guard let link = account.hub, link.hubID == hub.id else { continue }
            guard let login = listed[link.loginID] else {
                if missingBefore.contains(account.id) { removed.append(account.id) } else { missing.insert(account.id) }
                continue
            }
            guard !login.isDisabled, login.kind == account.kind, mirroredIDs.insert(login.id).inserted else {
                removed.append(account.id)
                continue
            }
            if let current = HubLink(hub: hub, login: login), current != link { relinked[account.id] = current }
        }
        added = logins.compactMap { login in
            guard !login.isDisabled, let kind = login.kind, let link = HubLink(hub: hub, login: login),
                  mirroredIDs.insert(login.id).inserted else { return nil }
            return (kind, login.label, link)
        }
    }
}

/// One entry of the hub's `GET /v0/management/auth-files` listing, reduced to what OpenUsage reads.
struct HubLogin: Equatable, Sendable {
    let id: String
    /// Nil when the hub listed the login without one; such a login can't be called.
    let authIndex: String?
    let provider: String
    let label: String
    let isOAuth: Bool
    let isDisabled: Bool
    let chatGPTAccountID: String?

    /// The OpenUsage provider a login is mirrored as, or nil for a login OpenUsage doesn't support yet.
    var kind: ProviderKind? {
        guard isOAuth else { return nil }
        return switch provider {
        case "claude": .claude
        case "codex": .codex
        case "antigravity": .antigravity
        case "devin": .devin
        case "xai": .grok
        default: nil
        }
    }

    /// The listing's logins in hub order. An entry without an id is skipped; an undecodable body throws.
    static func listing(from body: Data) throws -> [HubLogin] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let listing = try decoder.decode(Listing.self, from: body)
        return listing.files.compactMap { entry in
            guard let id = entry.id, !id.isEmpty else { return nil }
            let authIndex = entry.authIndex.flatMap { $0.isEmpty ? nil : $0 }
            let provider = (entry.provider ?? entry.type ?? "").lowercased()
            let label = [entry.email, entry.account, entry.label, entry.name].lazy
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? id
            return HubLogin(
                id: id,
                authIndex: authIndex,
                provider: provider,
                label: label,
                isOAuth: (entry.accountType ?? "oauth").lowercased() == "oauth",
                isDisabled: entry.disabled ?? false,
                chatGPTAccountID: entry.idToken?.chatgptAccountId
            )
        }
    }

    private struct Listing: Decodable {
        let files: [Entry]
    }

    private struct Entry: Decodable {
        let id: String?
        let authIndex: String?
        let provider: String?
        let type: String?
        let email: String?
        let account: String?
        let label: String?
        let name: String?
        let accountType: String?
        let disabled: Bool?
        let idToken: IDToken?
    }

    private struct IDToken: Decodable {
        let chatgptAccountId: String?
    }
}
