import Foundation

/// A CLIProxyAPI server the user connected with its management key. The hub owns its list of logins;
/// each supported login is mirrored as an ordinary Claude, ChatGPT, Antigravity, Devin, or Grok account
/// that carries a `HubLink`.
struct CLIProxyHub: Codable, Identifiable, Hashable, Sendable {
    /// The bundled mark (`ProviderIcons/cliproxyapi.svg`) on the hub's row and on its accounts' badge.
    static let markID = "cliproxyapi"
    /// Off until the feature is finished: Add Account offers no hub.
    static let isEnabled = false

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

    /// The hub's base URL from what the user typed: the scheme defaults to http, and the query, the
    /// fragment, and a pasted panel or API path (`/management.html`, `/v0/management`, `/v1`) are
    /// dropped. A path the hub sits under behind a reverse proxy is kept.
    static func baseURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
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
}

/// Where a mirrored account's login lives on its hub. `loginID` is the hub's stable id for the login
/// (its file name); `authIndex` is what `api-call` takes, and it changes when the hub renames the file.
struct HubLink: Codable, Hashable, Sendable {
    let hubID: UUID
    let hubURL: URL
    let loginID: String
    var authIndex: String

    var host: String { CLIProxyHub.host(of: hubURL) }

    init(hub: CLIProxyHub, login: HubLogin) {
        hubID = hub.id
        hubURL = hub.url
        loginID = login.id
        authIndex = login.authIndex
    }
}

/// What it takes to make a hub's mirrored accounts match its login list, in the listing's order. A login
/// disabled on the hub counts as gone.
struct HubReconciliation {
    var added: [(kind: ProviderKind, login: HubLogin)] = []
    var removed: [UUID] = []
    var relinked: [UUID: HubLink] = [:]

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && relinked.isEmpty }

    init(hub: CLIProxyHub, logins: [HubLogin], accounts: [Account]) {
        let supported = logins.filter { !$0.isDisabled }.compactMap { login in login.kind.map { (kind: $0, login: login) } }
        let byID = Dictionary(supported.map { ($0.login.id, $0) }, uniquingKeysWith: { first, _ in first })
        var mirroredIDs = Set<String>()
        for account in accounts {
            guard let link = account.hub, link.hubID == hub.id else { continue }
            guard let match = byID[link.loginID], match.kind == account.kind, mirroredIDs.insert(link.loginID).inserted else {
                removed.append(account.id)
                continue
            }
            let current = HubLink(hub: hub, login: match.login)
            if current != link { relinked[account.id] = current }
        }
        added = supported.filter { mirroredIDs.insert($0.login.id).inserted }
    }
}

/// One entry of the hub's `GET /v0/management/auth-files` listing, reduced to what OpenUsage reads.
struct HubLogin: Equatable, Sendable {
    let id: String
    let authIndex: String
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

    /// The listing's logins in hub order. An entry without an id or an auth index can't be called and is
    /// skipped; an undecodable body throws.
    static func listing(from body: Data) throws -> [HubLogin] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let listing = try decoder.decode(Listing.self, from: body)
        return listing.files.compactMap { entry in
            guard let id = entry.id, !id.isEmpty, let authIndex = entry.authIndex, !authIndex.isEmpty else { return nil }
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
